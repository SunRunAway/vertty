#!/usr/bin/env python3
"""Exercise real Sparkle UI/installers with disposable app IDs, keys and a local feed."""
import functools
import http.server
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import threading
import time
import uuid

import testapp

root = Path(tempfile.mkdtemp(prefix="vertty-update-", dir="/private/tmp"))
print(f"Artifacts: {root}", flush=True)
source = testapp.APP
tools = Path(".build/artifacts/sparkle/Sparkle/bin").resolve()
home, support, snapshot, feed, binaries, project = [root / n for n in ("home", "state", "snap", "feed", "bin", "project")]
for directory in (home, support, snapshot, feed, binaries, project, home / ".codex"):
    directory.mkdir(parents=True, exist_ok=True)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout.strip()


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(feed)))
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_port}/"
bundle_id = "dev.vertty.update-test." + uuid.uuid4().hex
env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
           CODEX_HOME=str(home / ".codex"), VERTTY_SUPPORT_DIR=str(support),
           VERTTY_DEBUG_SNAPSHOT=str(snapshot), VERTTY_TEST_UPDATES="1")
(home / ".zshenv").write_text(f'export PATH="{binaries}:/usr/bin:/bin:/usr/sbin:/sbin"\nunsetopt GLOBAL_RCS\n')
# A shell fixture, never a real agent. Its OSC title exercises the normal busy detection.
fake = binaries / "claude"
fake.write_text("#!/bin/sh\nprintf '\033]0;◐ Update fixture\007'\nexec /bin/cat\n")
fake.chmod(0o755)
project_id, tab_id = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
(support / "state.json").write_text(json.dumps({
    "projects": [{"id": project_id, "name": "Update fixture", "path": str(project), "expanded": True}],
    "tabs": [{"id": tab_id, "projectID": project_id, "kind": "claude", "sessionID": str(uuid.uuid4()),
              "title": "Update fixture", "cwd": str(project)}], "selectedTabID": tab_id,
}))
(support / "sleep-asked").touch()

# Generate a throwaway seed without writing any test credentials into Keychain.
key = root / "private-key"
key_source = root / "key.swift"
key_source.write_text('''import Foundation
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())
''')
public_key = run("swift", str(key_source), str(key))
key.chmod(0o600)


def app_copy(destination, version):
    run("ditto", str(source), str(destination))
    plist = destination / "Contents/Info.plist"
    info = plistlib.loads(plist.read_bytes())
    info.update(CFBundleIdentifier=bundle_id, CFBundleVersion=version, CFBundleShortVersionString=version,
                SUPublicEDKey=public_key, SUFeedURL=url + "appcast.xml", SUEnableAutomaticChecks=False,
                LSEnvironment={k: env[k] for k in (
                    "HOME", "CFFIXED_USER_HOME", "ZDOTDIR", "CODEX_HOME", "VERTTY_SUPPORT_DIR",
                    "VERTTY_DEBUG_SNAPSHOT", "VERTTY_TEST_UPDATES")})
    plist.write_bytes(plistlib.dumps(info))
    run("codesign", "--force", "--sign", "-", str(destination))
    run("codesign", "--verify", "--deep", "--strict", str(destination))


installed = root / "installed/Vertty.app"
new_app = root / "new/Vertty.app"
app_copy(installed, "1.0.0")
app_copy(new_app, "1.0.1")
# Reproduce the Brew postflight on the old app; the update has a fresh quarantine marker.
for app_path in (installed, new_app):
    run("xattr", "-w", "com.apple.quarantine", "0081;00000000;VerttyUpdateTest;", str(app_path))
run("xattr", "-dr", "com.apple.quarantine", str(installed))
archive = feed / "Vertty.zip"
run("ditto", "-c", "-k", "--keepParent", str(new_app), str(archive))
run(str(tools / "generate_appcast"), "--ed-key-file", str(key), "--maximum-deltas", "0",
    "--download-url-prefix", url, str(feed))
signed_feed = (feed / "appcast.xml").read_bytes()
signed_archive = archive.read_bytes()
key.unlink()


def state():
    path = snapshot / "state.txt"
    return path.read_text() if path.exists() else ""


def wait_for(predicate, message, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.2)
    log = root / "app.log"
    if app is not None and app.poll() is None:
        subprocess.run(["sample", str(app.pid), "1", "1", "-file", str(root / "timeout.sample")],
                       capture_output=True, timeout=15)
    raise AssertionError(message + "\n" + state() + "\n" + (log.read_text() if log.exists() else ""))


def send(command):
    path = snapshot / "input.txt"
    wait_for(lambda: not path.exists(), "debug driver stalled")
    path.write_text(command + "\n")
    wait_for(lambda: not path.exists(), "debug command was not consumed")


def click(title):
    translations = {"Cancel Update": "取消更新", "Install Update": "安装更新",
                    "Install and Relaunch": "安装并重启应用", "OK": "好", "Quit": "退出", "Cancel": "取消"}
    titles = "(?:" + "|".join(re.escape(t) for t in (title, translations.get(title, title))) + ")"
    match = wait_for(lambda: re.search(r"windowbutton=(\d+) enabled=true title=(" + titles + r")$", state(), re.M),
                     "missing button: " + title)
    send(f"windowbutton {match[1]} {match[2]}")


def version():
    return plistlib.loads((installed / "Contents/Info.plist").read_bytes())["CFBundleVersion"]


app = None
try:
    testapp.APP = installed
    app = testapp.launch(env, str(root / "app.log"))
    wait_for(lambda: "status=working" in state(), "fixture did not become busy")
    # A modified signed feed must not offer an install.
    (feed / "appcast.xml").write_bytes(signed_feed.replace(b"1.0.1", b"9.9.9"))
    send("checkupdates")
    click("Cancel Update")
    assert version() == "1.0.0"
    print("PASS tampered signed feed rejected", flush=True)
    (feed / "appcast.xml").write_bytes(signed_feed)
    # Corrupt the archive without changing its length or the signed feed.
    corrupt = bytearray(signed_archive)
    corrupt[len(corrupt) // 2] ^= 1
    archive.write_bytes(corrupt)
    send("checkupdates")
    click("Install Update")
    click("Cancel Update")
    assert version() == "1.0.0"
    print("PASS tampered update rejected before installation", flush=True)
    archive.write_bytes(signed_archive)
    send("checkupdates")
    click("Install Update")
    click("Install and Relaunch")
    wait_for(lambda: (snapshot / "alert.txt").exists() and any(t in (snapshot / "alert.txt").read_text() for t in ("Cancel", "取消")),
             "busy-agent exit confirmation was bypassed")
    click("Cancel")
    time.sleep(3)
    assert app.poll() is None and version() == "1.0.0"
    print("PASS cancelling busy-agent quit keeps old app running", flush=True)
    send("checkupdates")
    click("Install and Relaunch")
    wait_for(lambda: any(t in (snapshot / "alert.txt").read_text() for t in ("Quit", "退出")), "quit confirmation not shown again")
    click("Quit")
    wait_for(lambda: version() == "1.0.1", "app was not replaced")
    wait_for(lambda: "version=1.0.1" in state(), "updated app did not relaunch in scratch state")
    run("codesign", "--verify", "--deep", "--strict", str(installed))
    attrs = run("xattr", "-r", str(installed))
    assert "com.apple.quarantine" not in attrs, attrs
    assert (support / "state.json").exists()
    print("PASS signed update replaced and relaunched app, preserved state, removed quarantine", flush=True)
    send("checkupdates")
    click("OK")
    assert version() == "1.0.1"
    print("PASS current version reports no update", flush=True)
finally:
    server.shutdown()
    if app:
        app.terminate()
        app.wait(timeout=10)
    # Sparkle relaunches with a new PID. Only stop binaries inside this test's directory.
    for line in run("ps", "-axo", "pid=,args=").splitlines():
        parts = line.strip().split(None, 1)
        paths = (str(root) + "/", str(root).removeprefix("/private") + "/")
        if len(parts) == 2 and any(path in parts[1] for path in paths) and int(parts[0]) != os.getpid():
            try:
                os.kill(int(parts[0]), 15)
            except ProcessLookupError:
                pass
    key.unlink(missing_ok=True)
