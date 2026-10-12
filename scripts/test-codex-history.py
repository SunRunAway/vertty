#!/usr/bin/env python3
"""Run against a built app, with scratch state and no terminal sessions."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import uuid


def wait_for(check, description, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.2)
    raise AssertionError(description)


root = Path(tempfile.mkdtemp(dir="/private/tmp", prefix="vhostty-history-"))
print(f"Scratch artifacts: {root}", flush=True)
home = root / "codex"
project = root / "project"
support = root / "support"
snapshot = root / "snapshot"
for directory in (home, project, support, snapshot):
    directory.mkdir()
origin = "https://example.com/fixture.git"
subprocess.run(["git", "init", "-q", str(project)], check=True)
subprocess.run(["git", "-C", str(project), "remote", "add", "origin", origin], check=True)
# An existing Codex worktree folder that `git worktree list` no longer knows about.
(home / "worktrees" / "ab12" / project.name).mkdir(parents=True)

db_path = home / "state_5.sqlite"
with sqlite3.connect(db_path) as db:
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("""CREATE TABLE threads (
        id TEXT PRIMARY KEY, cwd TEXT, name TEXT, title TEXT, git_branch TEXT,
        updated_at INTEGER, rollout_path TEXT, archived INTEGER, source TEXT,
        thread_source TEXT, preview TEXT, git_origin_url TEXT)""")
    # Two sessions in the project, two of its repository in removed worktrees (one
    # in Codex's own worktree folder), and two that belong elsewhere.
    fixtures = [
        (project, "Codex fixture 0", origin), (project, "Codex fixture 1", origin),
        (home / "worktrees" / "ab12" / project.name, "Codex worktree fixture", origin),
        (root / "removed-worktree", "Removed worktree fixture", origin),
        (project / "sub", "Subdirectory fixture", origin),
        (root / "other-removed", "Other repository fixture", "https://example.com/other.git"),
    ]
    ids = [str(uuid.uuid4()) for _ in fixtures]
    for index, (cwd, name, url) in enumerate(fixtures):
        db.execute("INSERT INTO threads VALUES (?, ?, ?, ?, ?, ?, ?, 0, 'cli', 'user', 'prompt', ?)",
                   (ids[index], str(cwd), name, "prompt", "main", int(time.time()) - index,
                    str(root / f"rollout-{index}.jsonl"), url))
with sqlite3.connect(home / "thread_history_1.sqlite") as history:
    history.execute("""CREATE TABLE thread_items (
        thread_id TEXT, turn_id TEXT, item_id TEXT, rollout_ordinal INTEGER,
        created_at_ms INTEGER, item_json TEXT, item_type TEXT)""")
    for index, text in [(1, "first ask"), (1, 'find the "Needle"\nhere'), (3, 'a "needle" in a removed worktree'),
                        (5, 'a "needle" elsewhere')]:
        item = {"type": "userMessage", "content": [{"type": "text", "text": text}]}
        history.execute("INSERT INTO thread_items VALUES (?, 't', ?, ?, 0, ?, 'userMessage')",
                        (ids[index], str(uuid.uuid4()), len(text), json.dumps(item, ensure_ascii=False)))
(support / "state.json").write_text(json.dumps({
    "projects": [{"id": str(uuid.uuid4()), "name": "Fixture", "path": str(project), "expanded": True}],
    "tabs": [],
}))

state_path = snapshot / "state.txt"
log_path = root / "app.log"


def state():
    return state_path.read_text() if state_path.exists() else ""


def refresh():
    (snapshot / "input.txt").write_text("refreshhistory\n")
    wait_for(lambda: not (snapshot / "input.txt").exists(), "debug command not consumed")


env = dict(os.environ, CODEX_HOME=str(home), VHOSTTY_SUPPORT_DIR=str(support),
           VHOSTTY_DEBUG_SNAPSHOT=str(snapshot))
with log_path.open("w") as log:
    app = subprocess.Popen(["build/Vhostty.app/Contents/MacOS/Vhostty"], env=env,
                           stdout=log, stderr=subprocess.STDOUT)
    blocker = None
    try:
        wait_for(lambda: all(f"Codex fixture {i}" in state() for i in range(2)),
                 "initial Codex history not loaded")
        print("PASS initial history", flush=True)
        listed = state().split("history[Fixture]: ", 1)[1].split("\n", 1)[0]
        assert "Codex worktree fixture" in listed and "Removed worktree fixture" in listed, listed
        assert "Subdirectory fixture" not in listed and "Other repository fixture" not in listed, listed
        print("PASS removed worktrees of the repository listed", flush=True)
        (snapshot / "input.txt").write_text('search "needle"\n')
        wait_for(lambda: 'prompts[Fixture] "needle":' in state(), "prompt search not run")
        prompts = state().split('prompts[Fixture] "needle": ', 1)[1].split("\n", 1)[0]
        assert f'{ids[1]}=find the [\"Needle\"] here' in prompts, prompts
        assert ids[3] in prompts and ids[5] not in prompts and ids[0] not in prompts, prompts
        print("PASS prompt search", flush=True)
        # No explicit refresh: WAL writes must reach both history and an open search.
        (snapshot / "input.txt").write_text("search\n")
        wait_for(lambda: "search[Fixture]:" in state(), "search not loaded")
        started = time.monotonic()
        db.execute("UPDATE threads SET name = 'Event ' || name")
        db.commit()
        wait_for(lambda: "search[Fixture]: Event Codex fixture" in state()
                 and "history[Fixture]: Event Codex fixture" in state(),
                 "filesystem event did not refresh history and search", timeout=10)
        print(f"PASS automatic WAL/search refresh ({time.monotonic() - started:.1f}s)", flush=True)
        db.execute("UPDATE threads SET name = replace(name, 'Event ', '')")
        db.commit()
        wait_for(lambda: "Event Codex fixture" not in state(), "rename did not refresh", timeout=10)
        # The last writer checkpoints and removes WAL/SHM files when it closes.
        db.close()
        refresh()
        stamp = state_path.stat().st_mtime_ns
        wait_for(lambda: state_path.stat().st_mtime_ns > stamp, "snapshot not updated")
        assert all(f"Codex fixture {i}" in state() for i in range(2)), "closing last writer erased history"
        assert "unable to open database file" not in log_path.read_text(), "cannot read without WAL sidecars"
        print("PASS history after last writer closes", flush=True)
        blocker = sqlite3.connect(db_path, timeout=2)
        blocker.execute("PRAGMA locking_mode=EXCLUSIVE")
        blocker.execute("BEGIN EXCLUSIVE")
        refresh()
        wait_for(lambda: "database is locked" in log_path.read_text(), "locked read not exercised")
        # Allow the main queue and a subsequent debug snapshot to publish the result.
        stamp = state_path.stat().st_mtime_ns
        wait_for(lambda: state_path.stat().st_mtime_ns > stamp, "snapshot not updated")
        assert all(f"Codex fixture {i}" in state() for i in range(2)), "database lock erased history"
        print("PASS failed read preserves history", flush=True)
        blocker.rollback()
        blocker.close()
        blocker = None
        with sqlite3.connect(db_path) as db:
            db.execute("UPDATE threads SET name = 'Recovered ' || name")
        wait_for(lambda: "Recovered Codex fixture 0" in state(), "history did not recover")
        print("PASS refresh recovers after unlock", flush=True)
        with sqlite3.connect(db_path) as db:
            db.execute("DELETE FROM threads")
        wait_for(lambda: "Codex fixture" not in state(), "successful empty result retained stale history")
        print("PASS successful empty result clears history", flush=True)
        (snapshot / "input.txt").write_text("endsearch\n")
        wait_for(lambda: not (snapshot / "input.txt").exists(), "search not closed")
        with sqlite3.connect(db_path) as db:
            for index in range(57):
                db.execute("INSERT INTO threads VALUES (?, ?, ?, ?, ?, ?, ?, 0, 'cli', 'user', 'prompt', ?)",
                           (str(uuid.uuid4()), str(project), f"Page {index}", "prompt", "main",
                            int(time.time()) - index, str(root / f"page-{index}.jsonl"), origin))
        def pagination(count, more, expanded=True):
            expected = f"pagination[Fixture]: visible={count} more={str(more).lower()} expanded={str(expanded).lower()}"
            wait_for(lambda: expected in state(), expected)
        pagination(5, True)
        for count in (15, 25, 35, 45, 55, 57):
            (snapshot / "input.txt").write_text("morehistory\n")
            pagination(count, count < 57)
        (snapshot / "input.txt").write_text("toggleproject\n")
        pagination(5, True, False)
        (snapshot / "input.txt").write_text("toggleproject\n")
        pagination(5, True)
        print("PASS pagination beyond 40, final partial page, collapse/reopen reset", flush=True)
    finally:
        db.close()
        if blocker is not None:
            blocker.close()
        app.terminate()
        try:
            app.wait(timeout=10)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
