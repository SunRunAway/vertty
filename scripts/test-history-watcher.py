#!/usr/bin/env python3
"""Exercise real FSEvents using scratch files and a separate writer process."""
from pathlib import Path
import subprocess
import tempfile
import time

root = Path(tempfile.mkdtemp(dir="/private/tmp", prefix="vertty-watcher-"))
claude = root / "claude" / "projects"
codex = root / "codex"
codex.mkdir()
main = root / "main.swift"
main.write_text('''import Foundation
let watcher = HistoryWatcher(paths: CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }) {
    print("changed")
    fflush(stdout)
}
print("ready")
fflush(stdout)
RunLoop.main.run()
''')
binary = root / "watcher"
subprocess.run(["swiftc", "Sources/Vertty/Support/HistoryWatcher.swift", str(main), "-o", str(binary)], check=True)
log = root / "events.txt"
with log.open("w") as output:
    process = subprocess.Popen([str(binary), str(claude), str(codex)], stdout=output)
    try:
        def wait_for(check):
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if check():
                    return
                time.sleep(.05)
            raise AssertionError(log.read_text())

        wait_for(lambda: "ready" in log.read_text())
        def change(action, label):
            time.sleep(1)
            before = log.read_text().count("changed")
            start = time.monotonic()
            action()
            wait_for(lambda: log.read_text().count("changed") > before)
            print(f"PASS {label} ({time.monotonic() - start:.2f}s)", flush=True)

        change(lambda: claude.mkdir(parents=True), "missing Claude directory created")
        transcript = claude / "session.jsonl"
        change(lambda: transcript.write_text('{"type":"user"}\n'), "Claude transcript created")
        change(lambda: transcript.write_text('{"type":"user","message":"test"}\n'), "Claude transcript changed")
        change(lambda: transcript.unlink(), "Claude transcript removed")
        change(lambda: claude.rename(claude.with_name("old")), "Claude directory moved")
        change(lambda: claude.mkdir(), "Claude directory replaced")
        change(lambda: (claude / "new.jsonl").write_text('{}\n'), "replacement directory observed")
        change(lambda: (codex / "state_5.sqlite-wal").write_text('fixture'), "Codex WAL changed")
        time.sleep(1)
        before = log.read_text().count("changed")
        (codex / "unrelated.log").write_text('ignored')
        time.sleep(2)
        assert log.read_text().count("changed") == before, "unrelated file triggered refresh"
        print("PASS unrelated file ignored", flush=True)
    finally:
        process.terminate()
        process.wait(timeout=5)
print(f"Scratch artifacts: {root}")
