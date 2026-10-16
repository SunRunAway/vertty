#!/usr/bin/env python3
"""Launch the shipped zip in isolation, without relying on build-tree resources."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

import testapp

archive = Path(sys.argv[1] if len(sys.argv) > 1 else "build/Vertty.zip").resolve()
with tempfile.TemporaryDirectory(prefix="vertty-release-test-") as scratch:
    root = Path(scratch)
    subprocess.run(["ditto", "-x", "-k", str(archive), scratch], check=True)
    testapp.APP = root / "Vertty.app"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(testapp.APP)], check=True)
    state = root / "state"
    state.mkdir()
    env = dict(os.environ, VERTTY_SUPPORT_DIR=str(state), VERTTY_DEBUG_SNAPSHOT=str(state))
    app = None
    # launch() accepts a file object; its .name preserves the full log path.
    with (root / "app.log").open("w+") as log:
        try:
            app = testapp.launch(env, log)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if app.poll() is not None:
                    raise RuntimeError("Packaged app exited during startup")
                snapshot = state / "state.json"
                if snapshot.exists():
                    json.loads(snapshot.read_text())
                    time.sleep(2)
                    if app.poll() is not None:
                        raise RuntimeError("Packaged app exited after creating its UI")
                    print("Packaged app started and produced a debug snapshot")
                    break
                time.sleep(0.2)
            else:
                raise RuntimeError("Packaged app did not produce a debug snapshot")
        except Exception:
            log.seek(0)
            print(log.read(), file=sys.stderr)
            raise
        finally:
            if app is not None:
                app.terminate()
                app.wait(timeout=10)
