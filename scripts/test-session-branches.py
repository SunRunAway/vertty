#!/usr/bin/env python3
"""Exercise shared-checkout cards in a scratch app with fake agents and gh."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import testapp
import uuid


def wait_for(check, description, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.2)
    raise AssertionError(description + "\n" + state())


root = Path(tempfile.mkdtemp(dir="/private/tmp", prefix="vhostty-branches-"))
print(f"Scratch artifacts: {root}", flush=True)
home, project, support, snapshot, bin_dir = [root / n for n in ("home", "repo", "state", "snap", "bin")]
for directory in (home, project, support, snapshot, bin_dir, home / ".codex"):
    directory.mkdir(parents=True, exist_ok=True)


def git(*args):
    subprocess.run(["git", "-C", str(project), *args], check=True, capture_output=True)


git("init", "-q", "-b", "master")
git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "--allow-empty", "-qm", "fixture")
git("switch", "-qc", "feature/new")
encoded = "".join(c if c.isascii() and c.isalnum() else "-" for c in str(project))
transcripts = home / ".claude" / "projects" / encoded
transcripts.mkdir(parents=True)
project_id = str(uuid.uuid4()).upper()
names = ["New", "Old", "Codex", "Unknown", "Other feature"]
tabs = {name: {"id": str(uuid.uuid4()).upper(), "projectID": project_id,
               "kind": "codex" if name == "Codex" else "claude",
               "sessionID": str(uuid.uuid4()), "title": name, "cwd": str(project)} for name in names}
# Seed the wrong values previously persisted by HEAD-based polling.
tabs["Old"].update(branch="feature/new", prNumber=771, prURL="https://example.com/pull/771")


def transcript(name, branch, pr=None):
    rows = [{"type": "ai-title", "aiTitle": name},
            {"type": "assistant", "cwd": str(project), "gitBranch": branch}]
    if pr is not None:
        rows.append({"type": "pr-link", "prNumber": pr, "prUrl": f"https://example.com/pull/{pr}"})
    (transcripts / (tabs[name]["sessionID"] + ".jsonl")).write_text(
        "".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows))


transcript("New", "feature/new", 771)
transcript("Old", "master", 769)
transcript("Other feature", "feature/old", 769)
db = sqlite3.connect(home / ".codex" / "state_5.sqlite")
db.execute("""CREATE TABLE threads (
    id TEXT PRIMARY KEY, cwd TEXT, name TEXT, title TEXT, git_branch TEXT,
    updated_at INTEGER, rollout_path TEXT, archived INTEGER, source TEXT,
    thread_source TEXT, preview TEXT, git_origin_url TEXT)""")
db.execute("INSERT INTO threads VALUES (?, ?, 'Codex', 'Codex', 'feature/codex', ?, '', 0, 'cli', 'user', '', '')",
           (tabs["Codex"]["sessionID"], str(project), int(time.time())))
db.commit()

# Both login environment discovery and terminal launch use only the fake tools.
(home / ".zshenv").write_text(f'export PATH="{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin"\nunsetopt GLOBAL_RCS\n')
for agent in ("claude", "codex"):
    path = bin_dir / agent
    path.write_text("#!/bin/sh\nexit 0\n")
    path.chmod(0o755)
gh = bin_dir / "gh"
gh.write_text(f"#!{sys.executable}\n" + '''import json, sys
ref = sys.argv[3]
numbers = {"feature/new": 771, "feature/old": 769, "feature/codex": 770, "feature/next": 772}
number = numbers.get(ref)
if ref.startswith("https://example.com/pull/"):
    number = int(ref.rsplit("/", 1)[1])
if number is None:
    sys.exit(1)
print(json.dumps({"number": number, "url": f"https://example.com/pull/{number}", "state": "OPEN"}))
''')
gh.chmod(0o755)
(support / "state.json").write_text(json.dumps({
    "projects": [{"id": project_id, "name": "Fixture", "path": str(project), "expanded": True}],
    "tabs": list(tabs.values()), "selectedTabID": tabs["New"]["id"],
}))
state_path = snapshot / "state.txt"


def state():
    return state_path.read_text() if state_path.exists() else ""


def card(name, branch, pr):
    marker = "--- tab " + tabs[name]["id"]
    text = state()
    if marker not in text:
        return False
    block = text.split(marker, 1)[1].split("--- tab ", 1)[0]
    return f"branch={branch} worktree=- pr={pr} " in block


def stable(check, description):
    # Observe at least two four-second polling cycles after an external checkout.
    end = time.monotonic() + 10
    while time.monotonic() < end:
        assert check(), description + "\n" + state()
        time.sleep(0.2)
    print("PASS " + description, flush=True)


env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
           CODEX_HOME=str(home / ".codex"), VHOSTTY_SUPPORT_DIR=str(support),
           VHOSTTY_DEBUG_SNAPSHOT=str(snapshot))
with (root / "app.log").open("w") as log:
    app = testapp.launch(env, log)
    try:
        expected = lambda: (card("New", "feature/new", 771) and card("Old", "master", 769)
                            and card("Codex", "feature/codex", 770)
                            and card("Other feature", "feature/old", 769)
                            and card("Unknown", "-", "-"))
        wait_for(expected, "session branches and PRs were overwritten by shared HEAD")
        print("PASS restored cards corrected from their own session records", flush=True)
        git("switch", "-qc", "feature/unrelated")
        stable(expected, "checkout changes cannot overwrite Claude, Codex, or unknown cards")
        # This session moves to a new feature branch with no PR; its old pr-link
        # must not leak through (regression covered by e0d62d4).
        transcript("New", "feature/no-pr", 771)
        wait_for(lambda: card("New", "feature/no-pr", "-"), "old PR leaked into a new feature branch")
        print("PASS new feature branch clears the session's old PR", flush=True)
        transcript("New", "feature/next", 771)
        wait_for(lambda: card("New", "feature/next", 772), "own branch change did not refresh PR")
        print("PASS own session branch change refreshes PR", flush=True)
        transcript("New", "master", 772)
        wait_for(lambda: card("New", "master", 772), "return to master lost the linked PR")
        print("PASS return to master retains own linked PR", flush=True)
        db.execute("UPDATE threads SET git_branch = 'feature/next'")
        db.commit()
        wait_for(lambda: card("Codex", "feature/next", 772), "Codex session branch update ignored")
        assert card("Old", "master", 769) and card("Other feature", "feature/old", 769)
        print("PASS Codex metadata updates without changing other cards", flush=True)
    finally:
        db.close()
        app.terminate()
        try:
            app.wait(timeout=10)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
