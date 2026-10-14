#!/usr/bin/env python3
"""Exercise the iOS client in the iOS simulator against a scratch server.

Starts a scratch instance of build/Vhostty.app with a project, a card and a
fake agent (logs its terminal size and input), launches the iOS app in a
simulator with its debug driver (Documents/debug/input.txt and state.txt),
and checks connecting, the terminal, sizes, input, new sessions and being
replaced by another client. Build first:

make app && (cd VhosttyKit && swift build --product remote-probe)
xcodebuild -project iOS/Vhostty.xcodeproj -scheme Vhostty \\
    -destination 'platform=iOS Simulator,name=iPhone 17' \\
    -derivedDataPath build/ios-dd build

SIM_DEVICE picks the simulator (default "iPhone 17"; an iPad such as
"iPad Air 11-inch (M4)" runs the same checks in the side-by-side layout).
A simulator this script boots is shut down again at the end.
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
APP = ROOT / "build/ios-dd/Build/Products/Debug-iphonesimulator/Vhostty.app"
PROBE = ROOT / "VhosttyKit/.build/debug/remote-probe"
BUNDLE = "dev.vhostty.remote"
DEVICE = os.environ.get("SIM_DEVICE", "iPhone 17")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def simctl(*args, check=True):
    return subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True, check=check).stdout


root = Path(tempfile.mkdtemp(dir="/private/tmp", prefix="vhostty-remote-ios-"))
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
(server_state / "remote-enabled").write_text("")
port = free_port()
url = f"ws://127.0.0.1:{port}"


def read(path):
    return path.read_text() if path.exists() else ""


debug_dir = None


def phone():
    return read(debug_dir / "state.txt") if debug_dir else ""


def wait(check, what, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.2)
    simctl("io", udid, "screenshot", str(root / "failure.png"), check=False)
    raise AssertionError(what + "\n--- phone\n" + phone() + "\n--- server\n" + read(server_snap / "state.txt")
                         + "\n--- agent\n" + read(agent_log))


def drive(*lines):
    target = debug_dir / "input.txt"
    wait(lambda: not target.exists(), "phone didn't take its last command")
    target.write_text("\n".join(lines) + "\n")


def server_drive(*lines):
    target = server_snap / "input.txt"
    wait(lambda: not target.exists(), "server didn't take its last command")
    target.write_text("\n".join(lines) + "\n")


def terminal(key):
    for line in phone().splitlines():
        if line.startswith("terminal "):
            for part in line.split():
                if part.startswith(key + "="):
                    return part[len(key) + 1:]
    return None


def settled_size(what):
    """The device's grid once the session has stayed at it for a second
    (the keyboard and its bar come up in steps)."""
    def at_own():
        own = terminal("own")
        return own not in (None, "-") and last_size() == own and terminal("session") == own

    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if at_own():
            own = terminal("own")
            time.sleep(1)
            if at_own() and terminal("own") == own:
                return own
        time.sleep(0.2)
    raise AssertionError(what + "\n" + phone())


def status():
    first = phone().split("\n", 1)[0]
    return first.split()[0][7:] if first.startswith("status=") else None


def last_size():
    sizes = [l[5:] for l in read(agent_log).splitlines() if l.startswith("size ")]
    return sizes[-1] if sizes else None


def input_size(hex_input):
    for line in read(agent_log).splitlines():
        parts = line.split()
        if parts[0] == "input" and parts[1] == hex_input:
            return parts[2]
    return None


for path, what in ((APP, "the iPhone app"), (PROBE, "remote-probe"), (ROOT / "build/Vhostty.app", "Vhostty.app")):
    if not path.exists():
        sys.exit(f"Build {what} first (see the top of this script): {path} is missing")

devices = json.loads(simctl("list", "devices", "available", "-j"))["devices"]
sim = next((d for runtime in devices.values() for d in runtime if d["name"] == DEVICE), None)
if sim is None:
    sys.exit(f"No simulator named {DEVICE}")
udid = sim["udid"]
booted_here = sim["state"] != "Booted"

base = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
            CODEX_HOME=str(home / ".codex"))
server = None
probe = None
try:
    with (root / "server.log").open("w") as log:
        server = subprocess.Popen(
            [str(ROOT / "build/Vhostty.app/Contents/MacOS/Vhostty")],
            env=dict(base, VHOSTTY_SUPPORT_DIR=str(server_state), VHOSTTY_DEBUG_SNAPSHOT=str(server_snap),
                     VHOSTTY_REMOTE_PORT=str(port)),
            stdout=log, stderr=subprocess.STDOUT)

    if booted_here:
        simctl("boot", udid)
    simctl("bootstatus", udid, "-b")
    simctl("install", udid, str(APP))
    subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE],
                   env=dict(os.environ, SIMCTL_CHILD_VHOSTTY_DEBUG="1"), check=True, capture_output=True)
    container = Path(simctl("get_app_container", udid, BUNDLE, "data").strip())
    debug_dir = container / "Documents" / "debug"
    (debug_dir / "input.txt").unlink(missing_ok=True)
    wait(lambda: (debug_dir / "state.txt").exists(), "the app's debug driver never started")

    def listening():
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
            return True
        except OSError:
            return False
    wait(listening, "server never listened")

    drive(f"connect {url}")
    wait(lambda: status() == "connected" and card_id in phone(), "the app didn't connect and list the card")
    print("PASS the app connects and lists the server's card", flush=True)

    drive("open 0")
    wait(lambda: "green prompt" in phone(), "the card's terminal didn't open")
    # An existing card opens for reading, without the keyboard. The size
    # settles a moment after opening.
    wait(lambda: (lambda own: own not in (None, "-") and last_size() == own and terminal("reported") == own
                  and terminal("session") == own)(terminal("own")),
         "session not at the device's size")
    own = terminal("own")
    assert terminal("scale") == "1.00", phone()
    assert terminal("keyboard") == "false", phone()
    simctl("io", udid, "screenshot", str(root / "terminal.png"))
    print(f"PASS opening shows the terminal at the device's size ({own}), without the keyboard", flush=True)

    drive("focus")
    wait(lambda: terminal("keyboard") == "true", "tapping the terminal didn't bring up the keyboard")
    own = settled_size("session not at the size with the keyboard up")
    drive("type hi")
    wait(lambda: input_size("69") is not None, "typing didn't reach the agent")
    assert input_size("68") == own and input_size("69") == own, read(agent_log)
    wait(lambda: "GOT 69" in phone(), "the echo didn't show on the iPhone")
    drive("insert 你好")
    wait(lambda: input_size("e4bda0e5a5bd") is not None, "committed IME text didn't reach the agent")
    assert input_size("e4bda0e5a5bd") == own, read(agent_log)
    drive("ctrlc")
    wait(lambda: input_size("03") is not None, "Ctrl+C didn't reach the agent")
    print("PASS typing, IME text and Ctrl+C reach the session at the device's size", flush=True)

    # Typing on the computer takes the session to the computer's size; the
    # iPhone shows it at that grid (scaled down when bigger), and typing on
    # the iPhone takes it back.
    server_drive(f"to {card_id}", "text x")
    wait(lambda: input_size("78") is not None, "typing on the computer didn't reach the agent")
    local = input_size("78")
    assert local != own, f"computer and iPhone sizes are both {own}"
    wait(lambda: terminal("session") == local and terminal("reported") == local,
         f"the iPhone didn't show the computer's size {local}")
    simctl("io", udid, "screenshot", str(root / "computer-size.png"))
    drive("type y")
    wait(lambda: input_size("79") is not None, "typing after the computer's input didn't reach the agent")
    assert input_size("79") == own, read(agent_log)
    wait(lambda: terminal("session") == own and terminal("scale") == "1.00", "the iPhone didn't take its size back")
    print(f"PASS each input lands at its sender's size (computer {local}, device {own})", flush=True)

    drive("back")
    wait(lambda: last_size() == local and f"--- tab {card_id}" in read(server_snap / "state.txt")
         and "remoteGrid=-" in read(server_snap / "state.txt"), "leaving didn't restore the computer's size")
    simctl("io", udid, "screenshot", str(root / "list.png"))
    print("PASS leaving restores the computer's size", flush=True)

    drive("new")
    wait(lambda: phone().count("\ncard ") == 2, "the new session didn't appear")
    wait(lambda: (lambda o: o not in (None, "-", card_id))(phone().split("open=")[1].split()[0] if "open=" in phone() else None),
         "the new session didn't open")
    wait(lambda: phone().count("green prompt") == 1 and "SIZE 137x54" not in phone(),
         "the new session's terminal didn't show")
    # Typing comes next in a new session: the keyboard is up.
    wait(lambda: terminal("keyboard") == "true", "the new session didn't bring up the keyboard")
    simctl("io", udid, "screenshot", str(root / "new-session.png"))
    drive("hidekeyboard")
    wait(lambda: terminal("keyboard") == "false", "the hide-keyboard key didn't hide the keyboard")
    print("PASS new session from the device, with the keyboard up; it hides", flush=True)

    # Another client takes over: the iPhone says so and doesn't reconnect,
    # even after coming back to the foreground.
    probe = subprocess.Popen([str(PROBE), url], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    probe.stdin.write("hello\n")
    probe.stdin.flush()
    wait(lambda: status() == "replaced", "the iPhone didn't show it was replaced")
    drive("background")
    drive("foreground")
    time.sleep(2)
    assert status() == "replaced", phone()
    simctl("io", udid, "screenshot", str(root / "replaced.png"))
    print("PASS another client replaces the device; it doesn't reconnect on its own", flush=True)
    print(f"Screenshots: {root}", flush=True)
finally:
    if probe:
        probe.terminate()
    simctl("terminate", udid, BUNDLE, check=False)
    if server:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
    if booted_here:
        simctl("shutdown", udid, check=False)
