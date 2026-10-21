#!/usr/bin/env python3
"""Exercise the iOS client in the iOS simulator against a scratch server.

Starts a scratch instance of build/Vertty.app with a project, a card and a
fake agent (logs its terminal size and input), launches the iOS app in a
simulator with its debug driver (Documents/debug/input.txt and state.txt),
and checks connecting, the terminal, sizes, input, new sessions, connecting
again when started, and being replaced by another client. Build first:

make app && (cd VerttyKit && swift build --product remote-probe)
scripts/build-ghostty-ios.sh   # once, and after changing the Ghostty patch
xcodebuild -project iOS/Vertty.xcodeproj -scheme Vertty \\
    -destination 'platform=iOS Simulator,name=iPhone 17' \\
    -derivedDataPath build/ios-dd build

INPUT_ONLY=1 stops after the input bar's checks (typing, keys, paste).
PASTE_DIAGNOSTICS=1 also checks paste control reuse, sparse persistent logs,
background/foreground events, relaunch, and log rotation (simulator only).
SIM_DEVICE picks the simulator (default "iPhone 17"; an iPad such as
"iPad Air 11-inch (M4)" runs the same checks in the side-by-side layout).
A simulator this script boots is shut down again at the end.
"""
import json
import os
import re
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import testapp
import uuid

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build/ios-dd/Build/Products/Debug-iphonesimulator/Vertty.app"
PROBE = ROOT / "VerttyKit/.build/debug/remote-probe"
BUNDLE = "dev.vertty.remote"
DEVICE = os.environ.get("SIM_DEVICE", "iPhone 17")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def simctl(*args, check=True):
    return subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True, check=check).stdout


def forget_connection():
    """Clears the address and connection the run saved in the app, so the
    next person to open it doesn't find this run's random port."""
    container = simctl("get_app_container", udid, BUNDLE, "data", check=False).strip()
    if container:
        prefs = f"{container}/Library/Preferences/{BUNDLE}"
        for key in ("RemoteAddress", "RemoteTailnetComputer", "RemoteConnectionToken"):
            simctl("spawn", udid, "defaults", "delete", prefs, key, check=False)


root = Path(tempfile.mkdtemp(dir="/private/tmp", prefix="vertty-remote-ios-"))
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
# Tracks the mouse (SGR reports), as Claude Code does.
os.write(1, b"\\x1b[?1000h\\x1b[?1006h\\x1b[1;32mgreen prompt\\x1b[0m > ")
tty.setraw(0)
notification_count = 0
while True:
    b = os.read(0, 1024)
    if not b:
        break
    c, r = os.get_terminal_size(0)
    os.write(log, f"input {{b.hex()}} {{c}}x{{r}}\\n".encode())
    os.write(1, ("GOT " + b.hex() + "\\r\\n").encode())
    if b"!" in b:
        notification_count += 1
        os.write(1, f"\\x1b]9;Agent needs you {{notification_count}}\\x07".encode())
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
    if debug_dir and (debug_dir / "terminal.log").exists():
        (root / "terminal.log").write_bytes((debug_dir / "terminal.log").read_bytes())
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
    """The size the agent was at when it read these bytes; keys typed
    quickly can arrive in one read ("type hi" as 6869)."""
    for line in read(agent_log).splitlines():
        parts = line.split()
        if parts[0] == "input" and any(parts[1][i:i + len(hex_input)] == hex_input
                                       for i in range(0, len(parts[1]), 2)):
            return parts[2]
    return None


def inputs():
    """Every read the agent made, as (hex, size)."""
    return [(p[1], p[2]) for p in (l.split() for l in read(agent_log).splitlines()) if p and p[0] == "input"]


def composer():
    """What the bar's text field holds (its first line)."""
    for line in phone().splitlines():
        if line.startswith("composer|"):
            return line[len("composer|"):]
    return None


for path, what in ((APP, "the iPhone app"), (PROBE, "remote-probe"), (ROOT / "build/Vertty.app", "Vertty.app")):
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
        server = testapp.launch(
            dict(base, VERTTY_SUPPORT_DIR=str(server_state), VERTTY_DEBUG_SNAPSHOT=str(server_snap),
                 VERTTY_REMOTE_PORT=str(port)), log)

    if booted_here:
        simctl("boot", udid)
    simctl("bootstatus", udid, "-b")
    simctl("install", udid, str(APP))
    def launch():
        subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE],
                       env=dict(os.environ, SIMCTL_CHILD_VERTTY_DEBUG="1"), check=True, capture_output=True)
    container = Path(simctl("get_app_container", udid, BUNDLE, "data").strip())
    debug_dir = container / "Documents" / "debug"
    # A state.txt left by an earlier run would pass for this one's.
    for name in ("input.txt", "state.txt"):
        (debug_dir / name).unlink(missing_ok=True)
    paste_log = container / "Documents" / "paste-control.jsonl"
    if os.environ.get("PASTE_DIAGNOSTICS"):
        simctl("terminate", udid, BUNDLE, check=False)
        paste_log.parent.mkdir(parents=True, exist_ok=True)
        # Existing logs must survive startup; a full file rotates on the first write.
        paste_log.write_bytes(b" " * (2 * 1024 * 1024))
        for index in range(1, 4):
            Path(str(paste_log) + f".{index}").write_text(f"previous-{index}\n")
    launch()
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

    server_drive(f"to {card_id}", "text !")
    wait(lambda: "attention=true" in phone() and "attention=true" in read(server_snap / "state.txt"),
         "unopened card wasn't unread on both devices")

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
    assert terminal("config") == "ok", phone()
    simctl("io", udid, "screenshot", str(root / "terminal.png"))
    print(f"PASS opening shows the terminal at the device's size ({own}), without the keyboard", flush=True)
    wait(lambda: "attention=false" in phone() and "attention=false" in read(server_snap / "state.txt"),
         "opening on the phone didn't mark the card read on both devices")
    server_drive(f"to {card_id}", "text !")
    wait(lambda: "Agent needs you 2" in read(root / "server.log"), "second notification wasn't delivered")
    time.sleep(1)
    wait(lambda: "attention=false" in phone() and "attention=false" in read(server_snap / "state.txt"),
         "new output while reading on the phone stayed unread")
    print("PASS opening and reading new output on the phone clears shared unread state", flush=True)

    # A tap on the terminal is only a click for the program; the keyboard
    # stays away.
    count = len(inputs())
    drive("tap")
    wait(lambda: any(h.startswith("1b5b3c30") for h, _ in inputs()[count:]), "the tap's click didn't reach the agent")
    assert all(size == own for _, size in inputs()[count:]), read(agent_log)
    time.sleep(0.5)
    assert terminal("keyboard") == "false", phone()
    print("PASS a tap on the terminal only clicks", flush=True)

    # The bar's keyboard key brings the keyboard up.
    drive("key keyboard")
    wait(lambda: terminal("keyboard") == "true", "the keyboard key didn't bring up the keyboard")
    assert terminal("bar") == "keys", phone()
    own = settled_size("session not at the size with the keyboard up")
    simctl("io", udid, "screenshot", str(root / "keyboard-keys.png"))
    # With the keyboard up too, a tap only clicks: the keyboard stays.
    count = len(inputs())
    drive("tap")
    wait(lambda: any(h.startswith("1b5b3c30") for h, _ in inputs()[count:]), "a tap with the keyboard up didn't click")
    time.sleep(0.5)
    assert terminal("keyboard") == "true", phone()
    # With nothing typed, Return and Backspace are the terminal's, as are
    # the bar's keys and sliding on the space bar (Left presses).
    for command, sent, what in (("enter", "0d", "Return"), ("backspace", "7f", "Backspace"),
                                ("key esc", "1b", "Esc"), ("key ⇧←", "1b5b313b3244", "Shift-Left"),
                                ("key ^c", "03", "Ctrl+C"), ("key ↓", "1b5b42", "Down"),
                                ("slide -2", "1b5b44", "sliding on the space bar")):
        count = len(inputs())
        drive(command)
        wait(lambda: any(h.startswith(sent) for h, _ in inputs()[count:]), f"{what} with nothing typed didn't reach the agent")
        assert all(size == own for _, size in inputs()[count:]), read(agent_log)
    wait(lambda: re.search(r"GOT (..)*7f", phone()), "the echo didn't show on the iPhone")
    assert terminal("bar") == "keys" and composer() == "", phone()
    print("PASS with nothing typed, Return, Backspace, the bar's keys and space-bar sliding reach the session",
          flush=True)

    # The paste key pastes text into the field, to edit before sending.
    drive("key paste")
    wait(lambda: composer() == "pasted" and terminal("bar") == "field", "the paste key didn't fill the field")
    count = len(inputs())
    drive("send")
    wait(lambda: [h for h, _ in inputs()[count:]][-2:] == ["706173746564", "0d"], "the pasted text didn't send")
    wait(lambda: terminal("bar") == "keys", "the field didn't empty after sending")
    print("PASS the paste key fills the field", flush=True)

    # Typing goes into the field, which takes the keys' place (an IME
    # composition already does); Return there is a line break. Send pastes
    # it all, then presses Enter.
    count = len(inputs())
    drive("mark ni")
    wait(lambda: terminal("bar") == "field", "a composition didn't bring up the field")
    drive("type hi", "enter", "type 你好")
    wait(lambda: composer() == "hi", "typing didn't go into the field")
    simctl("io", udid, "screenshot", str(root / "keyboard-field.png"))
    time.sleep(0.5)
    assert inputs()[count:] == [], read(agent_log)
    drive("send")
    wait(lambda: "0d" in [h for h, _ in inputs()[count:]][1:], "sending didn't paste the text and press Enter")
    sent = [h for h, _ in inputs()[count:]]
    assert "".join(sent[:-1]) in ("68690de4bda0e5a5bd", "68690ae4bda0e5a5bd") and sent[-1] == "0d", sent
    assert all(size == own for _, size in inputs()[count:]), read(agent_log)
    wait(lambda: terminal("bar") == "keys" and composer() == "", "the field didn't empty after sending")
    print("PASS typing fills the field in the keys' place; sending pastes it and presses Enter", flush=True)

    # Put away with something typed (the keyboard key beside the field),
    # the field keeps it for the next time.
    drive("type draft")
    wait(lambda: terminal("bar") == "field", "typing didn't bring up the field")
    drive("key keyboard")
    wait(lambda: terminal("keyboard") == "false" and terminal("bar") == "keys", "the keyboard didn't go away")
    assert composer() == "draft", phone()
    drive("key keyboard")
    wait(lambda: terminal("keyboard") == "true" and terminal("bar") == "field", "the draft didn't come back")
    count = len(inputs())
    drive("send")
    wait(lambda: any(h.startswith("6472616674") for h, _ in inputs()[count:]), "the draft didn't send")
    print("PASS a draft stays in the field while the keyboard is away", flush=True)
    if os.environ.get("PASTE_DIAGNOSTICS"):
        def paste_entries():
            return [json.loads(line) for line in read(paste_log).splitlines() if line.strip()]

        def recorded(event):
            return [entry for entry in paste_entries() if entry["event"] == event]

        assert Path(str(paste_log) + ".1").stat().st_size == 2 * 1024 * 1024
        assert Path(str(paste_log) + ".2").read_text() == "previous-1\n"
        assert Path(str(paste_log) + ".3").read_text() == "previous-2\n"
        assert not Path(str(paste_log) + ".4").exists()
        drive("key diagnostic-snapshot")
        wait(lambda: recorded("diagnostic-snapshot"), "missing paste snapshot")
        original = recorded("diagnostic-snapshot")[-1]
        assert original["ownsPasteControl"] and original["targetMatches"]
        assert original["control"]["children"]
        assert recorded("pasteCallback") and recorded("pasteTextLoaded")
        assert all(word not in read(paste_log) for word in ("hello", "pasted", "draft")), "text leaked into diagnostics"
        # An idle visible bar no longer polls or writes recurring snapshots.
        time.sleep(1)
        idle_size = paste_log.stat().st_size
        time.sleep(3)
        assert paste_log.stat().st_size == idle_size, "idle bar still writes diagnostics"
        # Navigation must move the already rendered native control to the
        # next bar, keeping its identity and rebinding its paste target.
        previous = original
        for _ in range(2):
            drive("back")
            wait(lambda: terminal("bar") is None, "leaving didn't remove the bar")
            # Selection clears before the navigation animation removes the
            # outgoing controller; don't reopen while it is still on screen.
            wait(lambda: any(e["bar"] == previous["bar"] for e in recorded("detached")),
                 "leaving didn't detach the paste control")
            drive("open 0")
            wait(lambda: terminal("bar") == "keys", "reopening didn't show the bar")
            samples = len(recorded("diagnostic-snapshot"))
            drive("key diagnostic-snapshot")
            wait(lambda: len(recorded("diagnostic-snapshot")) > samples, "missing reopened paste snapshot")
            current = recorded("diagnostic-snapshot")[-1]
            assert current["bar"] != previous["bar"], "navigation reused the old bar"
            assert current["control"]["id"] == previous["control"]["id"], "navigation recreated the paste control"
            assert current["ownsPasteControl"] and current["targetMatches"] and current["control"]["inWindow"]
            previous = current
        print("PASS navigation keeps the native paste control and rebinds it to the visible bar", flush=True)
        # A real app lifecycle transition, not the debug driver's network simulation.
        simctl("launch", udid, "com.apple.Preferences")
        wait(lambda: recorded("UIApplicationDidEnterBackgroundNotification"), "background not persisted")
        simctl("launch", udid, BUNDLE)
        wait(lambda: recorded("UIApplicationDidBecomeActiveNotification"), "foreground not persisted")
        old_runs = {e["run"] for e in recorded("launch")}
        launch()
        wait(lambda: len({e["run"] for e in recorded("launch")}) > len(old_runs), "relaunch lost logs")
        assert recorded("diagnostic-snapshot"), "old events lost after relaunch"
        (root / "paste-control.jsonl").write_text(read(paste_log))
        print("PASS sparse paste diagnostics capture reuse, lifecycle, rotation, and survive relaunch without text", flush=True)
    if os.environ.get("INPUT_ONLY"):
        sys.exit(0)

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

    # A tap on the iPhone takes the session to its size before its click; a
    # click in the computer's window takes it back.
    count = len(inputs())
    drive("tap")
    wait(lambda: last_size() == own and terminal("session") == own, "a tap didn't take the session to the iPhone's size")
    wait(lambda: any(h.startswith("1b5b3c30") for h, _ in inputs()[count:]), "the tap's click didn't reach the agent")
    assert all(size == own for _, size in inputs()[count:]), read(agent_log)
    server_drive("postclick 900 400")
    wait(lambda: last_size() == local and terminal("session") == local, "a click on the computer didn't take its size back")
    print("PASS a tap on the iPhone and a click on the computer each take the session to their size", flush=True)

    # Going to the background doesn't change the session's size; coming
    # back does.
    simctl("launch", udid, "com.apple.Preferences")
    time.sleep(3)
    assert last_size() == local, read(agent_log)
    server_drive(f"to {card_id}", "text !")
    wait(lambda: "attention=true" in read(server_snap / "state.txt"), "background phone cleared unread output")
    time.sleep(1)
    assert "attention=true" in read(server_snap / "state.txt"), "background connection marked output read"
    simctl("launch", udid, BUNDLE)
    own = settled_size("coming back to the foreground didn't take the iPhone's size")
    wait(lambda: "attention=false" in phone() and "attention=false" in read(server_snap / "state.txt"),
         "returning to the phone didn't clear unread output")
    print("PASS background output stays unread until the phone returns to the foreground", flush=True)
    server_drive(f"to {card_id}", "text z")
    wait(lambda: input_size("7a") == local, "typing on the computer didn't take its size back")
    print("PASS going to the background keeps the size; coming back takes it", flush=True)

    drive("type y", "send")
    wait(lambda: input_size("79") is not None, "typing after the computer's input didn't reach the agent")
    assert input_size("79") == own, read(agent_log)
    wait(lambda: terminal("session") == own and terminal("scale") == "1.00", "the iPhone didn't take its size back")
    print(f"PASS each input lands at its sender's size (computer {local}, device {own})", flush=True)

    drive("back")
    wait(lambda: last_size() == local and f"--- tab {card_id}" in read(server_snap / "state.txt")
         and "remoteGrid=-" in read(server_snap / "state.txt"), "leaving didn't restore the computer's size")
    simctl("io", udid, "screenshot", str(root / "list.png"))
    print("PASS leaving restores the computer's size", flush=True)

    # The project row has a new-session button per agent the computer enables.
    wait(lambda: "kinds=claude,codex" in phone(), "the device didn't get both agents")
    simctl("io", udid, "screenshot", str(root / "list-both-agents.png"))
    server_drive("toggleagent codex")
    wait(lambda: "kinds=claude\n" in phone(), "turning Codex off on the computer didn't reach the device")
    simctl("io", udid, "screenshot", str(root / "list-claude-only.png"))
    server_drive("toggleagent codex")
    wait(lambda: "kinds=claude,codex" in phone(), "turning Codex back on didn't reach the device")
    print("PASS the device follows the computer's enabled agents", flush=True)

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

    # Quit while connected and started again: it connects on its own.
    (debug_dir / "state.txt").unlink(missing_ok=True)
    launch()
    wait(lambda: status() == "connected" and card_id in phone(), "the app didn't connect again when started")
    print("PASS started again, the app connects to the same computer", flush=True)

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

    # Started again after that: it doesn't take the connection back.
    (debug_dir / "state.txt").unlink(missing_ok=True)
    launch()
    wait(lambda: status() == "none", "restarting after replacement didn't show the address screen")
    print("PASS started again after being replaced, it waits on the address screen", flush=True)
    print(f"Screenshots: {root}", flush=True)
finally:
    if probe:
        probe.terminate()
    simctl("terminate", udid, BUNDLE, check=False)
    forget_connection()
    if server:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
    if booted_here:
        simctl("shutdown", udid, check=False)
