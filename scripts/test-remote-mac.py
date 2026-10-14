#!/usr/bin/env python3
"""Exercise the desktop remote client against a scratch server.

Starts two scratch instances of build/Vhostty.app: a server with a project, a
card and a fake agent (logs its terminal size and input), and a client with
no projects that opens a remote window to the server through the debug
driver. Checks that the remote window lists the card, shows its terminal at
the window's size and types into it. Build first with make app.
"""
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


root = Path(tempfile.mkdtemp(dir="/private/tmp", prefix="vhostty-remote-mac-"))
print(f"Scratch artifacts: {root}", flush=True)
home, project, bin_dir = root / "home", root / "project", root / "bin"
server_state, server_snap = root / "server-state", root / "server-snap"
client_state, client_snap = root / "client-state", root / "client-snap"
for d in (home, project, bin_dir, server_state, server_snap, client_state, client_snap, home / ".codex"):
    d.mkdir(parents=True, exist_ok=True)

agent_log = root / "agent.log"
agent = f"""#!{sys.executable}
import os, signal, sys, tty
log = os.open({str(agent_log)!r}, os.O_WRONLY | os.O_APPEND | os.O_CREAT)
def report(*_):
    c, r = os.get_terminal_size(0)
    os.write(log, f"size {{c}}x{{r}}\\n".encode())
    os.write(1, f"\\r\\nSIZE {{c}}x{{r}}\\r\\n".encode())
signal.signal(signal.SIGWINCH, report)
report()
os.write(1, b"\\x1b[1;32mgreen prompt\\x1b[0m > ")
tty.setraw(0)
while True:
    b = os.read(0, 1024)
    if not b:
        break
    c, r = os.get_terminal_size(0)
    os.write(log, f"input {{b.hex()}} {{c}}x{{r}}\\n".encode())
    os.write(1, ("GOT " + b.hex() + "\\r\\n").encode())
"""
for name in ("claude", "codex"):
    p = bin_dir / name
    p.write_text(agent)
    p.chmod(0o755)
(home / ".zshenv").write_text(f'export PATH="{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin"\nunsetopt GLOBAL_RCS\n')
db = sqlite3.connect(home / ".codex" / "state_5.sqlite")
db.execute("""CREATE TABLE threads (
    id TEXT PRIMARY KEY, cwd TEXT, name TEXT, title TEXT, git_branch TEXT,
    updated_at INTEGER, rollout_path TEXT, archived INTEGER, source TEXT,
    thread_source TEXT, preview TEXT, git_origin_url TEXT)""")
db.commit()
db.close()

project_id = str(uuid.uuid4()).upper()
card_id = str(uuid.uuid4()).upper()
(server_state / "state.json").write_text(json.dumps({
    "projects": [{"id": project_id, "name": "Fixture", "path": str(project), "expanded": True}],
    "tabs": [{"id": card_id, "projectID": project_id, "kind": "claude", "sessionID": str(uuid.uuid4()),
              "title": "Server card", "cwd": str(project)}],
    "selectedTabID": card_id,
}))
(server_state / "remote-enabled").write_text("")
(client_state / "state.json").write_text(json.dumps({"projects": [], "tabs": []}))
port = free_port()


def read(path):
    return path.read_text() if path.exists() else ""


def wait(check, what, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.2)
    if os.environ.get("SAMPLE_ON_FAIL"):
        subprocess.run(["sample", str(apps[1].pid), "1", "-file", str(root / "sample.txt")], capture_output=True)
    raise AssertionError(what + "\n--- client\n" + read(client_snap / "state.txt")
                         + "\n--- agent\n" + read(agent_log))


def drive(*lines):
    target = client_snap / "input.txt"
    wait(lambda: not target.exists(), "client didn't take its last command")
    target.write_text("\n".join(lines) + "\n")


def remote_line(key):
    for line in read(client_snap / "state.txt").splitlines():
        if line.startswith("    terminal ") or line.startswith("=== remote"):
            for part in line.split():
                if part.startswith(key + "="):
                    return part[len(key) + 1:]
    return None


def last_size():
    sizes = [l[5:] for l in read(agent_log).splitlines() if l.startswith("size ")]
    return sizes[-1] if sizes else None


def input_size(hex_input):
    for line in read(agent_log).splitlines():
        parts = line.split()
        if parts[0] == "input" and parts[1] == hex_input:
            return parts[2]
    return None


base = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
            CODEX_HOME=str(home / ".codex"))
apps = []
try:
    with (root / "server.log").open("w") as log:
        apps.append(subprocess.Popen(
            [str(ROOT / "build/Vhostty.app/Contents/MacOS/Vhostty")],
            env=dict(base, VHOSTTY_SUPPORT_DIR=str(server_state), VHOSTTY_DEBUG_SNAPSHOT=str(server_snap),
                     VHOSTTY_REMOTE_PORT=str(port)),
            stdout=log, stderr=subprocess.STDOUT))
    with (root / "client.log").open("w") as log:
        apps.append(subprocess.Popen(
            [str(ROOT / "build/Vhostty.app/Contents/MacOS/Vhostty")],
            env=dict(base, VHOSTTY_SUPPORT_DIR=str(client_state), VHOSTTY_DEBUG_SNAPSHOT=str(client_snap),
                     VHOSTTY_REMOTE_PORT=str(free_port())),
            stdout=log, stderr=subprocess.STDOUT))

    def listening():
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
            return True
        except OSError:
            return False
    wait(listening, "server never listened")
    wait(lambda: (client_snap / "state.txt").exists(), "client never started")

    drive(f"remote ws://127.0.0.1:{port}")
    wait(lambda: remote_line("status") == "connected" and card_id in read(client_snap / "state.txt"),
         "remote window didn't connect and list the card")
    print("PASS remote window connects and lists the server's card", flush=True)

    drive("remoteopen 0")
    wait(lambda: remote_line("open") == card_id and "green prompt" in read(client_snap / "state.txt"),
         "card's terminal didn't open")
    own = remote_line("own")
    wait(lambda: last_size() == own and remote_line("grid") == own,
         f"session not at the remote window's size {own}")
    print(f"PASS opening shows the terminal at the window's size ({own})", flush=True)

    drive("remotetext hi")
    wait(lambda: input_size("6869") is not None, "typing in the remote window didn't reach the agent")
    assert input_size("6869") == own, read(agent_log)
    wait(lambda: "GOT 6869" in read(client_snap / "state.txt"), "echo didn't show in the remote terminal")
    print("PASS typing reaches the session and its output shows", flush=True)

    drive("remotenew")
    wait(lambda: read(client_snap / "state.txt").count("    card ") == 2, "new session didn't appear")
    wait(lambda: remote_line("open") not in (None, "-", card_id), "new session didn't open")
    print("PASS new session from the remote window", flush=True)
    print(f"Screenshot: {client_snap / 'remote.png'}", flush=True)
finally:
    for app in apps:
        app.terminate()
    for app in apps:
        try:
            app.wait(timeout=10)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
