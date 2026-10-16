#!/usr/bin/env python3
"""Exercise the iOS client over the embedded Tailscale device.

Starts a scratch instance of build/Vertty.app set to "Via Tailscale", with a
project, a card and a fake agent, and the iOS app (freshly installed) in a
simulator with its debug driver. Both sign in with a Tailscale auth key from
TS_AUTHKEY (tsnet reads it from the environment; the simulator app gets it
as SIMCTL_CHILD_TS_AUTHKEY); use a key for test devices only (reusable,
ephemeral, no tags). Checks that the app lists the computer, connects,
drives the card, connects again through Tailscale when started again, and
signs out. Build first as for scripts/test-remote-ios.py.

    TS_AUTHKEY="$(cat <key file>)" python3 scripts/test-remote-ios-tailscale.py
"""
import json
import os
import re
import socket
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import testapp
import uuid

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build/ios-dd/Build/Products/Debug-iphonesimulator/Vertty.app"
BUNDLE = "dev.vertty.remote"
DEVICE = os.environ.get("SIM_DEVICE", "iPhone 17")

if not os.environ.get("TS_AUTHKEY", "").startswith("tskey-auth-"):
    sys.exit("Set TS_AUTHKEY to a Tailscale auth key for test devices.")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def simctl(*args, check=True):
    return subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True, check=check).stdout


def tailnet_line(text):
    for line in text.splitlines():
        if line.startswith("tailnet "):
            return line
    return ""


def tailnet_field(text, key):
    for part in tailnet_line(text).split():
        if part.startswith(key + "="):
            return part[len(key) + 1:]
    return None


root = Path(tempfile.mkdtemp(dir="/private/tmp", prefix="vertty-remote-ios-tailscale-"))
print(f"Scratch artifacts: {root}", flush=True)
home, project, bin_dir = root / "home", root / "project", root / "bin"
server_state, server_snap = root / "server-state", root / "server-snap"
for d in (home, project, bin_dir, server_state, server_snap, home / ".codex"):
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
(server_state / "remote-enabled").write_text("tailscale")
port = free_port()


def read(path):
    return path.read_text() if path.exists() else ""


debug_dir = None


def phone():
    return read(debug_dir / "state.txt") if debug_dir else ""


def wait(check, what, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.2)
    simctl("io", udid, "screenshot", str(root / "failure.png"), check=False)
    if debug_dir and (debug_dir / "terminal.log").exists():
        (root / "terminal.log").write_bytes((debug_dir / "terminal.log").read_bytes())
    raise AssertionError(what + "\n--- phone\n" + phone() + "\n--- server\n" + tailnet_line(read(server_snap / "state.txt"))
                         + "\n--- agent\n" + read(agent_log))


def drive(*lines):
    target = debug_dir / "input.txt"
    wait(lambda: not target.exists(), "phone didn't take its last command")
    target.write_text("\n".join(lines) + "\n")


def status():
    first = phone().split("\n", 1)[0]
    return first.split()[0][7:] if first.startswith("status=") else None


def last_size():
    sizes = [l[5:] for l in read(agent_log).splitlines() if l.startswith("size ")]
    return sizes[-1] if sizes else None


def input_size(hex_input):
    """The size the agent was at when it read these bytes; keys typed
    quickly can arrive in one read ("type hi" as 6869)."""
    for line in read(agent_log).splitlines():
        parts = line.split()
        if parts[0] == "input" and any(parts[1][i:i + len(hex_input)] == hex_input
                                       for i in range(0, len(parts[1]), 2)):
            return parts[2]
    return None



def settle(check, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return True
        time.sleep(0.2)
    return False


def sign_out(inbox, state):
    """Signs a test device out, best effort: Tailscale removes an ephemeral
    device as soon as it signs out, but keeps listing one that only went
    offline for up to an hour, on the user's other devices too."""
    if not settle(lambda: tailnet_field(state(), "signedIn") == "true", 0.5):
        return
    if settle(lambda: not inbox.exists(), 5):
        inbox.write_text("tailnetlogout\n")
        settle(lambda: tailnet_field(state(), "signedIn") == "false", 15)


for path, what in ((APP, "the iPhone app"), (ROOT / "build/Vertty.app", "Vertty.app")):
    if not path.exists():
        sys.exit(f"Build {what} first (see scripts/test-remote-ios.py): {path} is missing")

devices = json.loads(simctl("list", "devices", "available", "-j"))["devices"]
sim = next((d for runtime in devices.values() for d in runtime if d["name"] == DEVICE), None)
if sim is None:
    sys.exit(f"No simulator named {DEVICE}")
udid = sim["udid"]
booted_here = sim["state"] != "Booted"

base = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
            CODEX_HOME=str(home / ".codex"))
server = None
try:
    with (root / "server.log").open("w") as log:
        server = testapp.launch(
            dict(base, VERTTY_SUPPORT_DIR=str(server_state), VERTTY_DEBUG_SNAPSHOT=str(server_snap),
                 VERTTY_REMOTE_PORT=str(port)), log)

    if booted_here:
        simctl("boot", udid)
    simctl("bootstatus", udid, "-b")
    # Fresh: no Tailscale login, saved address or connection left over.
    simctl("uninstall", udid, BUNDLE, check=False)
    simctl("install", udid, str(APP))

    def launch():
        subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE],
                       env=dict(os.environ, SIMCTL_CHILD_VERTTY_DEBUG="1",
                                SIMCTL_CHILD_TS_AUTHKEY=os.environ["TS_AUTHKEY"]),
                       check=True, capture_output=True)
    container = Path(simctl("get_app_container", udid, BUNDLE, "data").strip())
    debug_dir = container / "Documents" / "debug"
    launch()
    wait(lambda: (debug_dir / "state.txt").exists(), "the app's debug driver never started")

    server_state_txt = lambda: read(server_snap / "state.txt")
    wait(lambda: tailnet_field(server_state_txt(), "signedIn") == "true", "the server didn't sign in to Tailscale", 90)
    server_name = tailnet_field(server_state_txt(), "name")

    # The first command starts the app's Tailscale device; once it lists the
    # computer, the second connects.
    drive(f"tailnet {server_name}")
    wait(lambda: f"{server_name}:online" in (tailnet_field(phone(), "computers") or ""),
         "the app didn't list the computer on Tailscale", 90)
    drive(f"tailnet {server_name}")
    wait(lambda: status() == "connected" and card_id in phone(), "the app didn't connect over Tailscale")
    print(f"PASS the app lists {server_name} on Tailscale and connects", flush=True)

    drive("open 0")
    wait(lambda: "green prompt" in phone(), "the card's terminal didn't open")
    drive("focus")
    drive("type hi")
    wait(lambda: input_size("69") is not None, "typing didn't reach the agent")
    wait(lambda: re.search(r"GOT (..)*69", phone()), "the echo didn't show on the iPhone")
    simctl("io", udid, "screenshot", str(root / "terminal.png"))
    print("PASS the card's terminal opens and typing round-trips over Tailscale", flush=True)

    launch()
    wait(lambda: status() == "connected" and card_id in phone(),
         "started again, the app didn't connect to the computer through Tailscale", 90)
    print("PASS started again, the app connects to the same computer through Tailscale", flush=True)

    drive("disconnect")
    drive("tailnetlogout")
    wait(lambda: tailnet_field(phone(), "signedIn") == "false" and status() == "none", "the app didn't sign out")
    simctl("io", udid, "screenshot", str(root / "signed-out.png"))
    print(f"PASS signing out (Tailscale state: {tailnet_field(phone(), 'state')})", flush=True)
    print(f"Screenshots: {root}", flush=True)
finally:
    if debug_dir:
        sign_out(debug_dir / "input.txt", phone)
    if server:
        sign_out(server_snap / "input.txt", lambda: read(server_snap / "state.txt"))
    simctl("terminate", udid, BUNDLE, check=False)
    if server:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
    if booted_here:
        simctl("shutdown", udid, check=False)
