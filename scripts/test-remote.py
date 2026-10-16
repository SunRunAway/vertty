#!/usr/bin/env python3
"""Exercise the remote service of a scratch app with a scripted client.

Starts build/Vertty.app on a scratch state dir, HOME and project, with fake
agents (a program that reports its terminal size and echoes its input), and
drives it with VerttyKit's remote-probe over 127.0.0.1. Build first:
make app && (cd VerttyKit && swift build --product remote-probe)
"""
import json
import os
from pathlib import Path
import queue
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import testapp
import uuid

ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / "VerttyKit/.build/debug/remote-probe"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


root = Path(tempfile.mkdtemp(dir="/private/tmp", prefix="vertty-remote-"))
print(f"Scratch artifacts: {root}", flush=True)
home, project, support, snapshot, bin_dir = [root / n for n in ("home", "project", "state", "snap", "bin")]
for d in (home, project, support, snapshot, bin_dir, home / ".codex"):
    d.mkdir(parents=True, exist_ok=True)

# The fake agent logs its terminal size (at start and on every resize) and
# its input with the terminal size at the time it read it to agent.log;
# echoes input in hex; and sends a desktop notification on "!".
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
tty.setraw(0)
while True:
    b = os.read(0, 1024)
    if not b:
        break
    c, r = os.get_terminal_size(0)
    os.write(log, f"input {{b.hex()}} {{c}}x{{r}}\\n".encode())
    os.write(1, ("GOT " + b.hex() + "\\r\\n").encode())
    if b"!" in b:
        os.write(1, b"\\x1b]9;Agent needs you\\x07")
"""
for name in ("claude", "codex"):
    p = bin_dir / name
    p.write_text(agent)
    p.chmod(0o755)
(home / ".zshenv").write_text(f'export PATH="{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin"\nunsetopt GLOBAL_RCS\n')

# A project with one restored card and two past Claude sessions.
encoded = "".join(c if c.isascii() and c.isalnum() else "-" for c in str(project))
transcripts = home / ".claude" / "projects" / encoded
transcripts.mkdir(parents=True)
project_id = str(uuid.uuid4()).upper()
card_id = str(uuid.uuid4()).upper()
card_session, past_session = str(uuid.uuid4()), str(uuid.uuid4())
for sid, title in ((card_session, "Card session"), (past_session, "Past session")):
    rows = [{"type": "ai-title", "aiTitle": title}, {"type": "assistant", "cwd": str(project)}]
    (transcripts / f"{sid}.jsonl").write_text(
        "".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows))
# A typed prompt in the card's session, for search.
(home / ".claude" / "history.jsonl").write_text(json.dumps(
    {"display": "fix the flaky deploy step", "sessionId": card_session, "project": str(project)}) + "\n")
# An empty Codex index (history reads fail without one).
db = sqlite3.connect(home / ".codex" / "state_5.sqlite")
db.execute("""CREATE TABLE threads (
    id TEXT PRIMARY KEY, cwd TEXT, name TEXT, title TEXT, git_branch TEXT,
    updated_at INTEGER, rollout_path TEXT, archived INTEGER, source TEXT,
    thread_source TEXT, preview TEXT, git_origin_url TEXT)""")
db.commit()
db.close()
(support / "state.json").write_text(json.dumps({
    "projects": [{"id": project_id, "name": "Fixture", "path": str(project), "expanded": True}],
    "tabs": [{"id": card_id, "projectID": project_id, "kind": "claude", "sessionID": card_session,
              "title": "Card session", "cwd": str(project)}],
}))
(support / "remote-enabled").write_text("")
port = free_port()
url = f"ws://127.0.0.1:{port}"


class Probe:
    def __init__(self, name):
        self.name = name
        self.events = queue.Queue()
        self.proc = subprocess.Popen([str(PROBE), url], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     text=True, bufsize=1)
        threading.Thread(target=self._read, daemon=True).start()

    last_state = None

    def _read(self):
        for line in self.proc.stdout:
            e = json.loads(line)
            if e["event"] == "state":
                self.last_state = e
            self.events.put(e)

    def wait_state(self, pred, what, timeout=15):
        """Waits until the latest State satisfies pred."""
        wait(lambda: self.last_state is not None and pred(self.last_state), f"{self.name}: {what}", timeout)
        return self.last_state

    def cmd(self, line):
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def expect(self, pred, what, timeout=15):
        deadline = time.monotonic() + timeout
        seen = []
        while time.monotonic() < deadline:
            try:
                e = self.events.get(timeout=max(0.05, deadline - time.monotonic()))
            except queue.Empty:
                break
            seen.append(e)
            if pred(e):
                return e
        raise AssertionError(f"{self.name}: {what}\nseen: {json.dumps(seen, indent=1)[-3000:]}\n{state()}")

    def expect_output(self, texts, what, timeout=15):
        """Waits until the terminal output since now contains every text."""
        seen = ""

        def pred(e):
            nonlocal seen
            if e["event"] in ("output", "snapshot"):
                seen += e["text"]
            return all(t in seen for t in texts)
        return self.expect(pred, what, timeout)

    def quiet(self, pred, what, duration=1.5):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            try:
                e = self.events.get(timeout=0.1)
            except queue.Empty:
                continue
            assert not pred(e), f"{self.name}: {what}: {e}"

    def close(self):
        try:
            self.cmd("quit")
        except BrokenPipeError:
            pass
        self.proc.wait(timeout=5)


def state():
    p = snapshot / "state.txt"
    return p.read_text() if p.exists() else ""


def drive(*lines):
    (snapshot / "input.txt").write_text("\n".join(lines) + "\n")


def tab_grid(tab):
    text = state()
    marker = "--- tab " + tab
    if marker not in text:
        return None
    block = text.split(marker, 1)[1].split("--- tab ", 1)[0]
    for part in block.split():
        if part.startswith("grid="):
            return part[5:]
    return None


def agent_saw(hex_input):
    """The terminal size when the agent read this input, once it has."""
    for line in (agent_log.read_text() if agent_log.exists() else "").splitlines():
        parts = line.split()
        if parts[0] == "input" and parts[1] == hex_input:
            return parts[2]
    return None


def agent_size():
    sizes = [l[5:] for l in (agent_log.read_text() if agent_log.exists() else "").splitlines() if l.startswith("size ")]
    return sizes[-1] if sizes else None


def output_with(text):
    return lambda e: e["event"] in ("output", "snapshot") and text in e["text"]


def wait(check, what, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.2)
    raise AssertionError(what + "\n" + state())


env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
           CODEX_HOME=str(home / ".codex"), VERTTY_SUPPORT_DIR=str(support),
           VERTTY_DEBUG_SNAPSHOT=str(snapshot), VERTTY_REMOTE_PORT=str(port))
probes = []
with (root / "app.log").open("w") as log:
    app = testapp.launch(env, log)
    try:
        # The service starts once the login shell's environment is read.
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
                break
            except OSError:
                time.sleep(0.2)
        else:
            raise AssertionError("the remote service never started listening")

        a = Probe("A")
        probes.append(a)
        a.cmd("hello")
        welcome = a.expect(lambda e: e["event"] == "welcome", "no welcome")
        # History is read in the background; a later State brings it.
        st = a.expect(lambda e: e["event"] == "state" and e["history"] and e["history"][0]["sessions"],
                      "no state with history")
        assert st["projects"][0]["id"] == project_id, st
        assert [c["id"] for c in st["cards"]] == [card_id], st
        assert st["history"][0]["sessions"] == [past_session], st
        print("PASS hello, welcome and state (projects, cards, history)", flush=True)

        # The menu item is on, with the port and the client under it.
        menu = lambda: (snapshot / "remote-menu.txt").read_text() if (snapshot / "remote-menu.txt").exists() else ""
        wait(lambda: "[on]" in menu() and str(port) in menu() and "Probe" in menu(),
             "the menu didn't show the port and the connected client")
        print("PASS the menu shows the port and who is connected", flush=True)

        # Opening a card puts the session at the client's size.
        a.cmd(f"open {card_id} 40 12")
        a.expect(lambda e: e["event"] == "snapshot" and e["cols"] == 40 and e["rows"] == 12,
                 "no snapshot at the client's size")
        wait(lambda: agent_size() == "40x12", "agent not resized to the client's size")
        wait(lambda: tab_grid(card_id) == "40x12", "local terminal not at the remote size")
        print("PASS open puts the session at the remote size", flush=True)

        a.cmd(f"align {card_id} 40 12")
        a.cmd(f"input {card_id} hi\\r")
        a.expect_output(["GOT 68690d"], "input's echo didn't come back")
        assert agent_saw("68690d") == "40x12", agent_log.read_text()
        print("PASS input reaches the session and its output streams back", flush=True)

        a.cmd(f"viewport {card_id} 50 15")
        a.expect(lambda e: e["event"] == "snapshot" and e["cols"] == 50 and e["rows"] == 15,
                 "no new snapshot after the viewport changed")
        wait(lambda: agent_size() == "50x15", "viewport change didn't resize the session")
        print("PASS viewport change resizes the session and resends the screen", flush=True)

        # Typing locally takes the session back to the local size; the
        # client's next input brings it back to the client's. Selecting the
        # card locally doesn't.
        drive(f"select {card_id}")
        wait(lambda: "selected: " + card_id in state(), "couldn't select the card locally")
        time.sleep(1)
        assert agent_size() == "50x15", "selecting the card locally changed the size"
        drive(f"to {card_id}", "text x")
        local = a.expect(lambda e: e["event"] == "snapshot" and (e["cols"], e["rows"]) != (50, 15),
                         "local typing didn't restore the local size")
        local_size = f"{local['cols']}x{local['rows']}"
        wait(lambda: agent_saw("78") is not None, "local input lost")
        assert agent_saw("78") == local_size, agent_log.read_text()
        a.cmd(f"align {card_id} 50 15")
        a.cmd(f"input {card_id} y")
        a.expect(lambda e: e["event"] == "snapshot" and e["cols"] == 50, "remote input didn't realign")
        wait(lambda: agent_saw("79") is not None, "remote input lost")
        assert agent_saw("79") == "50x15", agent_log.read_text()
        print("PASS each input lands at its sender's size (local and remote)", flush=True)

        # Input without AlignForInput (mouse, scrolling) never resizes.
        drive(f"to {card_id}", "text z")
        wait(lambda: agent_saw("7a") == local_size, "local typing didn't restore the local size")
        a.cmd(f"input {card_id} m")
        wait(lambda: agent_saw("6d") is not None, "plain input lost")
        assert agent_saw("6d") == local_size, agent_log.read_text()
        print("PASS input without AlignForInput keeps the size", flush=True)

        # Leaving returns the session to the local size.
        a.cmd(f"viewport {card_id} 44 13")
        wait(lambda: agent_size() == "44x13", "viewport not applied")
        a.cmd(f"leave {card_id}")
        wait(lambda: agent_size() == local_size and "remoteGrid=-" in state(),
             "leaving didn't restore the local size")
        print("PASS leaving restores the local size", flush=True)

        # New session: a retry with the same operation id doesn't create another.
        a.cmd(f"new {project_id} op-1")
        first = a.expect(lambda e: e["event"] == "reply" and "card" in e, "new session failed")
        a.cmd(f"new {project_id} op-1")
        again = a.expect(lambda e: e["event"] == "reply" and "card" in e, "retry failed")
        assert first["card"] == again["card"], (first, again)
        st = a.wait_state(lambda e: len(e["cards"]) == 2, "new card missing from state")
        assert st["cards"][0]["id"] == first["card"], "new card isn't at the top of its project"
        assert "selected: " + card_id in state(), "remote new session changed the local selection"
        print("PASS new session is idempotent and leaves the local selection alone", flush=True)

        # Resume: from history, and again returns the same card.
        a.cmd(f"resume {project_id} {past_session}")
        resumed = a.expect(lambda e: e["event"] == "reply" and "card" in e, "resume failed")
        a.cmd(f"resume {project_id} {past_session}")
        resumed2 = a.expect(lambda e: e["event"] == "reply" and "card" in e, "second resume failed")
        assert resumed["card"] == resumed2["card"]
        a.cmd(f"resume {project_id} {uuid.uuid4()}")
        a.expect(lambda e: e["event"] == "reply" and e.get("error") == 4, "resuming a missing session didn't fail")
        print("PASS resume reuses open cards and refuses unknown sessions", flush=True)

        # Closing a running card needs confirmation, like locally (unless
        # "Don't ask again" was checked, which State reports).
        if st["confirmClose"]:
            a.cmd(f"close {resumed['card']}")
            a.expect(lambda e: e["event"] == "reply" and e.get("error") == 5, "close didn't ask for confirmation")
            a.cmd(f"close {resumed['card']} confirm")
        else:
            a.cmd(f"close {resumed['card']}")
        a.expect(lambda e: e["event"] == "reply" and e.get("closed"), "close failed")
        a.wait_state(lambda e: resumed["card"] not in [c["id"] for c in e["cards"]], "closed card still in state")
        wait(lambda: resumed["card"] not in state(), "card not closed locally")
        print("PASS close asks for confirmation and closes the card", flush=True)

        a.cmd(f"history {project_id} 10")
        a.expect(lambda e: e["event"] == "reply" and "sessions" in e, "history request failed")
        print("PASS history request", flush=True)

        a.cmd(f"search {project_id} flaky")
        found = a.expect(lambda e: e["event"] == "reply" and "query" in e, "search failed")
        assert found["query"] == "flaky" and past_session in found["sessions"], found
        assert card_session not in found["sessions"], found
        assert {"session": card_session, "match": "flaky"} in found["prompts"], found
        print("PASS search returns closed sessions and typed prompts", flush=True)

        # The agent's notifications reach the client.
        a.cmd(f"open {card_id} 40 12")
        a.cmd(f"input {card_id} !")
        a.expect(lambda e: e["event"] == "notification" and e["card"] == card_id
                 and "Agent needs you" in e["title"] + e["body"], "notification not forwarded")
        print("PASS notifications are forwarded", flush=True)

        # One client at a time: B replaces A, A doesn't get back in on its own.
        a.cmd(f"open {card_id} 40 12")
        a.expect(lambda e: e["event"] == "snapshot", "reopen failed")
        b = Probe("B")
        probes.append(b)
        b.cmd("hello")
        b_welcome = b.expect(lambda e: e["event"] == "welcome", "B not welcomed")
        a.expect(lambda e: e["event"] == "replaced", "A wasn't told it was replaced")
        wait(lambda: "remoteGrid=-" in state() and agent_size() == local_size, "replaced client's size stayed")
        a2 = Probe("A again")
        probes.append(a2)
        a2.cmd("hello " + welcome["token"])
        a2.expect(lambda e: e["event"] == "error" and e["code"] == 7, "stale reconnect wasn't refused")
        b.wait_state(lambda e: True, "B got no state")
        print("PASS a new client replaces the old one; the old one can't reconnect on its own", flush=True)

        # B's connection drops; its own token is still the latest, so its
        # automatic reconnect is accepted.
        b.cmd("drop")
        time.sleep(0.5)
        b2 = Probe("B again")
        probes.append(b2)
        b2.cmd("hello " + b_welcome["token"])
        b2.expect(lambda e: e["event"] == "welcome", "reconnect with the latest token refused")
        print("PASS reconnecting with the latest token is accepted", flush=True)

        bad = Probe("old version")
        probes.append(bad)
        bad.cmd("badversion")
        bad.expect(lambda e: e["event"] == "error" and e["code"] == 1, "incompatible version accepted")
        print("PASS incompatible versions are refused", flush=True)
    finally:
        for p in probes:
            try:
                p.close()
            except Exception:
                p.proc.kill()
        app.terminate()
        try:
            app.wait(timeout=10)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
