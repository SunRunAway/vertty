#!/usr/bin/env python3
"""Regenerates docs/screenshot.png, the screenshot in the READMEs.

Builds two demo projects from scratch (starboard, 小账本) with git worktrees,
starts build/Vhostty.app against a scratch state dir and the debug driver
(see DEVELOPER.md), and captures the window with a brand-new Claude Code
session, which hasn't been given anything to do yet, in the selected card:

  starboard
    [selected] new Claude session, just started
    Claude session that finished in the background (blue dot)
    Codex card on feat/dark-mode with an open PR
    Claude card on chore/vite-6 with a merged PR
  小账本
    Claude card on main, Codex card with an open PR, Claude card with a closed PR

The two live sessions are real `claude` runs (they use your Claude account and
config, and the script answers Claude's trust prompt for the demo folders); the
other cards are restored, not-started cards from state.json.

Usage (run `make app` first; run it outside any sandbox):
  python3 scripts/readme-screenshot.py [--out docs/screenshot.png]

Claude transcripts of the
demo projects (~/.claude/projects/-private-tmp-vhostty-readme-demo-*) are
removed before and after the run so they never show up as history.
"""

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEMO = Path("/private/tmp/vhostty-readme-demo")
SUPPORT = DEMO / "support"
SNAP = DEMO / "snap"
STARBOARD = DEMO / "starboard"
ZHANGBEN = DEMO / "xiaozhangben"

DEFAULTS_DOMAIN = "dev.vhostty.Vhostty"
FRAME_KEY = "NSWindow Frame VhosttyMainWindow"
WINDOW_FRAME = "120 120 1100 840"   # points; the PNG comes out at 2x
SIDEBAR_WIDTH = 275

STARBOARD_ID = "6B1E3C0A-5F0D-4C55-9E1B-2B7C8E0F4A01"
ZHANGBEN_ID = "6B1E3C0A-5F0D-4C55-9E1B-2B7C8E0F4A02"

# The background session: a short question that finishes before the capture.
BACKGROUND_PROMPT = "Why does applyCoupon ignore FREESHIP codes? Just explain, don't change any files."

# --- demo repos ------------------------------------------------------------

STARBOARD_FILES = {
    "package.json": """{
  "name": "starboard",
  "private": true,
  "type": "module",
  "scripts": { "test": "node --test" }
}
""",
    "README.md": "# Starboard\n\nA small storefront.\n",
    "src/money.ts": """export type Cents = number;

export function formatPrice(cents: Cents, currency = "USD"): string {
  return new Intl.NumberFormat("en-US", { style: "currency", currency }).format(cents / 100);
}
""",
    "src/coupons.ts": """import type { Cents } from "./money.ts";

export interface Cart {
  subtotal: Cents;
  shipping: Cents;
}

const PERCENT_OFF: Record<string, number> = { WELCOME10: 10, SPRING20: 20 };

export function applyCoupon(cart: Cart, code: string): Cart {
  const normalized = code.trim();
  const percent = PERCENT_OFF[normalized.toUpperCase()];
  if (percent) {
    return { ...cart, subtotal: Math.round(cart.subtotal * (1 - percent / 100)) };
  }
  if (normalized === "FREE_SHIP") {
    return { ...cart, shipping: 0 };
  }
  return cart;
}
""",
    "test/coupons.test.ts": """import { test } from "node:test";
import assert from "node:assert/strict";
import { applyCoupon } from "../src/coupons.ts";

test("percent coupons take money off the subtotal", () => {
  assert.deepEqual(applyCoupon({ subtotal: 5000, shipping: 500 }, "welcome10"), { subtotal: 4500, shipping: 500 });
});

test("unknown coupons change nothing", () => {
  assert.deepEqual(applyCoupon({ subtotal: 5000, shipping: 500 }, "NOPE"), { subtotal: 5000, shipping: 500 });
});
""",
    "test/money.test.ts": """import { test } from "node:test";
import assert from "node:assert/strict";
import { formatPrice } from "../src/money.ts";

test("formats cents as dollars", () => {
  assert.equal(formatPrice(1999), "$19.99");
});
""",
}

ZHANGBEN_FILES = {
    "README.md": "# 小账本\n\n记一笔，看月度统计。\n",
    "zhangben/__init__.py": "",
    "zhangben/ledger.py": '''from dataclasses import dataclass
from datetime import datetime


@dataclass
class Entry:
    at: datetime
    amount: int  # 分
    category: str
    note: str = ""
''',
    "zhangben/stats.py": '''from collections import defaultdict

from .ledger import Entry


def monthly_totals(entries: list[Entry]) -> dict[str, int]:
    totals: dict[str, int] = defaultdict(int)
    for e in entries:
        totals[e.at.strftime("%Y-%m")] += e.amount
    return dict(totals)
''',
    "tests/test_stats.py": '''from datetime import datetime

from zhangben.ledger import Entry
from zhangben.stats import monthly_totals


def test_monthly_totals():
    entries = [Entry(datetime(2026, 9, 30), 1200, "餐饮"), Entry(datetime(2026, 10, 1), 800, "交通")]
    assert monthly_totals(entries) == {"2026-09": 1200, "2026-10": 800}
''',
}

# Branch / worktree of the restored cards.
WORKTREES = {
    STARBOARD: [("dark-mode", "feat/dark-mode"), ("vite-6", "chore/vite-6")],
    ZHANGBEN: [("csv-export", "feat/csv-export"), ("timezone-fix", "fix/timezone")],
}


def git(cwd, *args):
    env = dict(os.environ,
               GIT_AUTHOR_NAME="Starboard Dev", GIT_AUTHOR_EMAIL="dev@starboard.test",
               GIT_COMMITTER_NAME="Starboard Dev", GIT_COMMITTER_EMAIL="dev@starboard.test")
    subprocess.run(["git", *args], cwd=cwd, env=env, check=True, stdout=subprocess.DEVNULL)


def make_repo(path, files):
    path.mkdir(parents=True)
    for name, text in files.items():
        f = path / name
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)
    git(path, "init", "-q", "-b", "main")
    git(path, "add", "-A")
    git(path, "commit", "-q", "-m", "Initial commit")
    # Worktrees live where Claude Code puts them; keep them out of git status.
    (path / ".git/info/exclude").write_text(".claude/\n")
    for name, branch in WORKTREES[path]:
        git(path, "worktree", "add", "-q", "-b", branch, f".claude/worktrees/{name}")


def card(project_id, project_path, kind, title, branch, worktree=None, pr=None, pr_state=None):
    session = str(uuid.uuid4()) if kind == "claude" else "019a" + uuid.uuid4().hex[4:]
    record = {"id": str(uuid.uuid4()).upper(), "projectID": project_id, "kind": kind,
              "sessionID": session, "title": title,
              "cwd": str(project_path / ".claude/worktrees" / worktree) if worktree else str(project_path),
              "branch": branch}
    if worktree:
        record["worktree"] = worktree
    if pr:
        record.update(prNumber=pr, prURL=f"https://github.com/example/{project_path.name}/pull/{pr}",
                      prState=pr_state)
    return record


def write_state():
    """Returns the id of the card for the background session. It comes first and
    is selected, because Vhostty starts the selected card at launch; with no
    transcript yet, it starts as a new Claude session."""
    background = {"id": str(uuid.uuid4()).upper(), "projectID": STARBOARD_ID, "kind": "claude",
                  "sessionID": str(uuid.uuid4()), "title": "New Session", "cwd": str(STARBOARD)}
    tabs = [
        background,
        card(STARBOARD_ID, STARBOARD, "codex", "Add a dark mode toggle to settings", "feat/dark-mode",
             "dark-mode", 131, "OPEN"),
        card(STARBOARD_ID, STARBOARD, "claude", "Upgrade the build to Vite 6", "chore/vite-6",
             "vite-6", 129, "MERGED"),
        card(ZHANGBEN_ID, ZHANGBEN, "claude", "月度统计计算方式", "main"),
        card(ZHANGBEN_ID, ZHANGBEN, "codex", "导出账单支持 CSV", "feat/csv-export", "csv-export", 57, "OPEN"),
        card(ZHANGBEN_ID, ZHANGBEN, "claude", "修复跨时区的账单日期错位", "fix/timezone", "timezone-fix", 53, "CLOSED"),
    ]
    state = {
        "projects": [
            {"id": STARBOARD_ID, "name": "starboard", "path": str(STARBOARD), "expanded": True, "defaultKind": "claude"},
            {"id": ZHANGBEN_ID, "name": "小账本", "path": str(ZHANGBEN), "expanded": True, "defaultKind": "claude"},
        ],
        "tabs": tabs,
        "selectedTabID": background["id"],
        "lastProjectID": STARBOARD_ID,
        "detectedKind": "claude",
        "sidebarWidth": SIDEBAR_WIDTH,
        "sidebarVisible": True,
    }
    SUPPORT.mkdir(parents=True)
    (SUPPORT / "state.json").write_text(json.dumps(state, ensure_ascii=False, indent=2))
    return background["id"]


def claude_project_dirs():
    base = Path.home() / ".claude/projects"
    return [base / re.sub(r"[^A-Za-z0-9]", "-", str(p)) for p in (STARBOARD, ZHANGBEN)]


def remove_transcripts():
    for d in claude_project_dirs():
        shutil.rmtree(d, ignore_errors=True)


# --- debug driver ------------------------------------------------------------

def send(*lines):
    """Queues driver commands; the app consumes input.txt every 1.5 s."""
    path = SNAP / "input.txt"
    deadline = time.time() + 15
    while path.exists() and time.time() < deadline:
        time.sleep(0.3)
    path.write_text("\n".join(lines) + "\n")
    while path.exists() and time.time() < deadline:
        time.sleep(0.3)


def read_tabs():
    """Parses state.txt into {tab id: {kind, status, attention, text}}."""
    try:
        text = (SNAP / "state.txt").read_text()
    except FileNotFoundError:
        return {}
    tabs, current = {}, None
    for line in text.splitlines():
        m = re.match(r"--- tab (\S+) kind=(\w+) status=(\w+) attention=(\w+)", line)
        if m:
            current = {"kind": m[2], "status": m[3], "attention": m[4] == "true", "text": ""}
            tabs[m[1]] = current
        elif current is not None and line.startswith("    | "):
            current["text"] += line[6:] + "\n"
        elif current is not None and line.startswith("    title="):
            current["title"] = line[10:].split(" | ")[0]
    return tabs


def wait_for(what, check, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.5)
    sys.exit(f"timed out waiting for {what}")


def wait_until_ready(tab_id):
    def ready():
        text = read_tabs().get(tab_id, {}).get("text", "")
        # The first run in the demo folder asks whether to trust it.
        if "Yes, I trust this folder" in text:
            send(f"to {tab_id}", "down")
            send(f"to {tab_id}", "enter")
            time.sleep(2)
            return False
        # Claude's input box is up once its footer hint shows.
        return re.search(r"for shortcuts|bypass permissions|mode on", text)
    wait_for("Claude to start", ready, 60)


def new_claude_session():
    before = set(read_tabs())
    send("new claude")
    tab_id = wait_for("the new card", lambda: next(iter(set(read_tabs()) - before), None), 20)
    wait_until_ready(tab_id)
    return tab_id


def submit(tab_id, prompt):
    send(f"to {tab_id}", f"text {prompt}")
    time.sleep(1)
    send(f"to {tab_id}", "enter")
    wait_for("Claude to start working", lambda: read_tabs().get(tab_id, {}).get("status") == "working", 60)


def capture(main_id, background_id, out):
    """Waits until the new session's input box is up and the background card
    shows its blue dot, then saves a window image from that same tick."""
    def ready():
        tabs = read_tabs()
        bg = tabs.get(background_id, {})
        return bg.get("status") == "idle" and bg.get("attention") and tabs.get(main_id, {}).get("status") != "working"
    wait_for("the background session to finish", ready, 180)
    time.sleep(3)  # let Claude's start-up screen settle
    state_file = SNAP / "state.txt"
    while True:
        stamp = state_file.stat().st_mtime
        # window.png is written just before state.txt in the same tick.
        shutil.copy(SNAP / "window.png", out)
        if state_file.stat().st_mtime == stamp and ready():
            return
        time.sleep(0.5)


# --- app lifecycle -------------------------------------------------------------

def read_default(key):
    r = subprocess.run(["defaults", "read", DEFAULTS_DOMAIN, key], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def restore_default(key, value):
    if value is None:
        subprocess.run(["defaults", "delete", DEFAULTS_DOMAIN, key], capture_output=True)
    else:
        subprocess.run(["defaults", "write", DEFAULTS_DOMAIN, key, "-string", value], check=True)


def stop_children():
    """Stops what the demo's tabs started (they carry this support dir's socket)."""
    sock = f"VHOSTTY_SOCK={SUPPORT / 'hook.sock'}"
    out = subprocess.run(["ps", "-wwE", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        pid, _, rest = line.strip().partition(" ")
        if sock in rest.split() and int(pid) != os.getpid():
            try:
                os.kill(int(pid), signal.SIGTERM)
            except ProcessLookupError:
                pass


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", default=str(ROOT / "build/Vhostty.app"))
    ap.add_argument("--out", default=str(ROOT / "docs/screenshot.png"))
    args = ap.parse_args()

    binary = Path(args.app) / "Contents/MacOS/Vhostty"
    if not binary.exists():
        sys.exit(f"{binary} not found; run `make app` first")

    shutil.rmtree(DEMO, ignore_errors=True)
    remove_transcripts()
    make_repo(STARBOARD, STARBOARD_FILES)
    make_repo(ZHANGBEN, ZHANGBEN_FILES)
    background = write_state()
    SNAP.mkdir(parents=True)

    # The window frame autosaves into the app's defaults, shared with the
    # installed copy: pass ours on the command line, put the user's back after.
    saved_frame = read_default(FRAME_KEY)
    env = dict(os.environ, VHOSTTY_SUPPORT_DIR=str(SUPPORT), VHOSTTY_DEBUG_SNAPSHOT=str(SNAP))
    app = subprocess.Popen([str(binary), "-AppleLanguages", "(en)", "-AppleLocale", "en_US", f"-{FRAME_KEY}", WINDOW_FRAME],
                           env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_for("the app", lambda: (SNAP / "state.txt").exists(), 30)
        wait_until_ready(background)
        submit(background, BACKGROUND_PROMPT)
        main_tab = new_claude_session()
        capture(main_tab, background, args.out)
        print(f"wrote {args.out}")
    finally:
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(10)
        except subprocess.TimeoutExpired:
            app.kill()
        time.sleep(1)
        stop_children()
        restore_default(FRAME_KEY, saved_frame)
        remove_transcripts()


if __name__ == "__main__":
    main()
