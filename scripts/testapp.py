"""Starts a test instance of build/Vertty.app in the background.

Every test that runs Vertty starts it through `launch`, never by running
the binary directly: run that way, macOS brings the new app to the front, in
front of whatever the user is working in. `open -g` starts it without
activating it, and the app's test mode (VERTTY_DEBUG_SNAPSHOT) keeps its
window behind other windows, where window images still work.

    app = testapp.launch(env, log)   # env: the full environment for the app
    ...
    app.terminate(); app.wait(timeout=10)

The returned object has the subprocess.Popen calls the tests use: pid,
poll, terminate, kill, send_signal and wait.
"""
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid

APP = Path(__file__).resolve().parent.parent / "build/Vertty.app"


class App:
    def __init__(self, pid):
        self.pid = pid

    def poll(self):
        try:
            os.kill(self.pid, 0)
            return None
        except ProcessLookupError:
            return 0

    def send_signal(self, sig):
        try:
            os.kill(self.pid, sig)
        except ProcessLookupError:
            pass

    def terminate(self):
        self.send_signal(signal.SIGTERM)

    def kill(self):
        self.send_signal(signal.SIGKILL)

    def wait(self, timeout=None):
        deadline = None if timeout is None else time.monotonic() + timeout
        while self.poll() is None:
            if deadline is not None and time.monotonic() > deadline:
                raise subprocess.TimeoutExpired(str(APP), timeout)
            time.sleep(0.1)
        return 0


def launch(env, log=None):
    """Starts Vertty with the environment `env`, as subprocess.Popen would,
    and its output in `log` (a path or an open file); returns it once it's
    running."""
    marker = uuid.uuid4().hex
    cmd = ["open", "-n", "-g"]
    for key, value in env.items():
        if key != "_":  # the shell's last command, which open refuses
            cmd += ["--env", f"{key}={value}"]
    if log is not None:
        path = str(getattr(log, "name", log))
        cmd += ["--stdout", path, "--stderr", path]
    # A marker in its arguments tells this instance's pid apart from any
    # other Vertty, the user's included.
    cmd += [str(APP), "--args", "--vertty-test", marker]
    subprocess.run(cmd, check=True)
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        ps = subprocess.run(["ps", "-axo", "pid=,args="], capture_output=True, text=True).stdout
        for line in ps.splitlines():
            if marker in line:
                return App(int(line.split()[0]))
        time.sleep(0.1)
    raise RuntimeError("the test instance of Vertty didn't start")
