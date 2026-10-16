#!/usr/bin/env python3
"""Exercise remote connections through the embedded Tailscale device.

Starts two scratch instances of build/Vertty.app: a server with a project, a
card and a fake agent, set to "Via Tailscale", and a client that finds the
server on the tailnet and opens a remote window to it through the debug
driver. Both sign in with a Tailscale auth key from TS_AUTHKEY, which
Tailscale's tsnet reads from the environment; use a key for test devices
only (reusable, ephemeral, no tags), never the user's own login. Checks
that the server only listens on 127.0.0.1, the menu, that the client lists
the server and drives its card over Tailscale, that switching the server to
Own Network takes it off the tailnet, and signing out. Build first with
make app.

    TS_AUTHKEY="$(cat <key file>)" python3 scripts/test-remote-tailscale.py
"""
import json
import os
from pathlib import Path
import re
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import testapp
import uuid

ROOT = Path(__file__).resolve().parent.parent

if not os.environ.get("TS_AUTHKEY", "").startswith("tskey-auth-"):
    sys.exit("Set TS_AUTHKEY to a Tailscale auth key for test devices.")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


root = Path(tempfile.mkdtemp(dir="/private/tmp", prefix="vertty-remote-tailscale-"))
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

# Two past Claude sessions; a typed prompt in one of them, for search.
encoded = "".join(c if c.isascii() and c.isalnum() else "-" for c in str(project))
transcripts = home / ".claude" / "projects" / encoded
transcripts.mkdir(parents=True)
past = {str(uuid.uuid4()): "Tidy the docs", str(uuid.uuid4()): "Speed up the build"}
for sid, title in past.items():
    rows = [{"type": "ai-title", "aiTitle": title}, {"type": "assistant", "cwd": str(project)}]
    (transcripts / f"{sid}.jsonl").write_text("".join(json.dumps(r, separators=(",", ":")) + "\n" for r in rows))
(home / ".claude" / "history.jsonl").write_text(json.dumps(
    {"display": "cache the flaky step", "sessionId": list(past)[1], "project": str(project)}) + "\n")

project_id = str(uuid.uuid4()).upper()
card_id = str(uuid.uuid4()).upper()
(server_state / "state.json").write_text(json.dumps({
    "projects": [{"id": project_id, "name": "Fixture", "path": str(project), "expanded": True}],
    "tabs": [{"id": card_id, "projectID": project_id, "kind": "claude", "sessionID": str(uuid.uuid4()),
              "title": "Server card", "cwd": str(project)}],
    "selectedTabID": card_id,
}))
(server_state / "remote-enabled").write_text("tailscale")
(client_state / "state.json").write_text(json.dumps({"projects": [], "tabs": []}))
port = free_port()


def read(path):
    return path.read_text() if path.exists() else ""


def wait(check, what, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.2)
    if os.environ.get("SAMPLE_ON_FAIL"):
        subprocess.run(["sample", str(apps[1].pid), "1", "-file", str(root / "sample.txt")], capture_output=True)
    # The Tailscale account is masked.
    raise AssertionError(what + "\n--- server\n" + tailnet_line(server_snap) + "\n"
                         + re.sub(r"\S+@\S+", "<account>", read(server_snap / "remote-menu.txt"))
                         + "\n--- client\n" + read(client_snap / "state.txt")
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




def tailnet_line(snap):
    for line in read(snap / "state.txt").splitlines():
        if line.startswith("tailnet "):
            return line
    return ""


def tailnet_field(snap, key):
    for part in tailnet_line(snap).split():
        if part.startswith(key + "="):
            return part[len(key) + 1:]
    return None


def menu_ways():
    """The server menu's ways (as "[on]"/"[off]") and the lines under the
    checked one; the texts depend on the system's language."""
    lines = read(server_snap / "remote-menu.txt").splitlines()
    ways = [l for l in lines if not l.startswith("  ")]
    return [w.endswith("[on]") for w in ways], [l.strip() for l in lines if l.startswith("  ")]


def tcp_listeners(pid):
    out = subprocess.run(["lsof", "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN"],
                         capture_output=True, text=True).stdout
    return [l.split()[8] for l in out.splitlines()[1:]]


base = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
            CODEX_HOME=str(home / ".codex"))
apps = []
try:
    with (root / "server.log").open("w") as log:
        apps.append(testapp.launch(
            dict(base, VERTTY_SUPPORT_DIR=str(server_state), VERTTY_DEBUG_SNAPSHOT=str(server_snap),
                 VERTTY_REMOTE_PORT=str(port)), log))
    with (root / "client.log").open("w") as log:
        apps.append(testapp.launch(
            dict(base, VERTTY_SUPPORT_DIR=str(client_state), VERTTY_DEBUG_SNAPSHOT=str(client_snap),
                 VERTTY_REMOTE_PORT=str(free_port())), log))

    # Via Tailscale checked; under it the account, the name, the client
    # and Sign Out.
    wait(lambda: menu_ways()[0] == [True, False] and len(menu_ways()[1]) == 4 and "@" in menu_ways()[1][0],
         "the server's menu doesn't show it signed in to Tailscale")
    server_name = tailnet_field(server_snap, "name")
    assert server_name and server_name in menu_ways()[1][1], tailnet_line(server_snap)
    no_client = menu_ways()[1][2]
    print(f"PASS the server is on Tailscale as {server_name}; the menu shows the account and name", flush=True)

    listeners = tcp_listeners(apps[0].pid)
    assert listeners and all(l.startswith("127.0.0.1:") for l in listeners), listeners
    assert f"127.0.0.1:{port}" not in listeners, listeners
    print(f"PASS the server only listens on 127.0.0.1 ({', '.join(listeners)})", flush=True)

    # The first command starts the client's Tailscale device; once it lists
    # the server (and state.txt shows no window opened yet), the second
    # opens the window.
    drive(f"remotetailnet {server_name}")
    wait(lambda: f"{server_name}:online" in (tailnet_field(client_snap, "computers") or ""),
         "the client didn't list the server on Tailscale", timeout=90)
    time.sleep(2)
    if "=== remote" not in read(client_snap / "state.txt"):
        drive(f"remotetailnet {server_name}")
    wait(lambda: remote_line("status") == "connected" and card_id in read(client_snap / "state.txt"),
         "the client didn't connect over Tailscale")
    assert read(client_snap / "state.txt").count("=== remote") == 1, read(client_snap / "state.txt")
    assert f"{server_name}:online" in tailnet_field(client_snap, "computers"), tailnet_line(client_snap)
    print("PASS the client lists the server and connects over Tailscale", flush=True)
    wait(lambda: menu_ways()[1][2] != no_client, "the server's menu doesn't show the client")
    print("PASS the server's menu shows the connected client", flush=True)

    drive("remoteopen 0")
    wait(lambda: remote_line("open") == card_id and "green prompt" in read(client_snap / "state.txt"),
         "card's terminal didn't open")
    own = remote_line("own")
    wait(lambda: last_size() == own and remote_line("grid") == own,
         f"session not at the remote window's size {own}")
    drive("remotetext hi")
    wait(lambda: input_size("6869") == own, "typing in the remote window didn't reach the agent")
    wait(lambda: "GOT 6869" in read(client_snap / "state.txt"), "echo didn't show in the remote terminal")
    print(f"PASS the card's terminal opens at the window's size ({own}) and typing round-trips", flush=True)

    # Own Network: the server leaves the tailnet; the client loses it.
    (server_snap / "input.txt").write_text("remotemode direct\n")
    wait(lambda: menu_ways()[0] == [False, True] and str(port) in menu_ways()[1][0],
         "the server didn't switch to Own Network")
    wait(lambda: tailnet_field(server_snap, "state") == "stopped", "the server's Tailscale device kept running")
    # The client notices when its pings go unanswered.
    wait(lambda: remote_line("status") != "connected", "the client stayed connected", timeout=90)
    print("PASS Own Network stops the server's Tailscale device and drops the client", flush=True)

    drive("tailnetlogout")
    wait(lambda: tailnet_field(client_snap, "signedIn") == "false", "the client didn't sign out")
    print(f"PASS signing out on the client (Tailscale state: {tailnet_field(client_snap, 'state')})", flush=True)
finally:
    for app in apps:
        app.terminate()
    for app in apps:
        try:
            app.wait(timeout=10)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
