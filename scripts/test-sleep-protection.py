#!/usr/bin/env python3
"""Real watchdog with fake pmset; real AppKit onboarding via the debug driver.
Never authorizes or changes the host's power settings.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(tempfile.mkdtemp(prefix='vhostty-sleep-', dir='/private/tmp'))
print(f'Artifacts: {root}', flush=True)
binary = Path('build/Vhostty.app/Contents/MacOS').resolve()

def wait(check, message, timeout=25):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if check(): return
        time.sleep(.15)
    raise AssertionError(message)

def read(path):
    return path.read_text() if path.exists() else ''

case = root / 'watchdog'
case.mkdir()
(case / 'value').write_text('0')
def helper(*extra):
    return subprocess.Popen([str(binary / 'vhostty-sleep'), str(case), *extra, '--test-dir', str(case)],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE)
def end(p):
    p.stdin.close(); return p.wait(timeout=10)
p = helper()
try:
    assert p.stdout.readline() == b'active\n', 'lease did not report active'
    assert read(case / 'value') == '1', 'lease did not acquire'
    assert end(p) == 0 and read(case / 'value') == '0', 'EOF did not restore'
    print('PASS lease / EOF restoration', flush=True)
    p = helper(); p.stdout.readline()
    p.send_signal(15); p.wait(timeout=10)
    assert read(case / 'value') == '0', 'SIGTERM did not restore'
    print('PASS SIGTERM restoration', flush=True)
    # Restore even a pre-existing 1; only Amphetamine's two true states exempt it.
    for state in [None, 'true,true', 'true,false', 'false,true', 'false,false', 'error']:
        amphetamine = case / 'amphetamine'
        if state is None: amphetamine.unlink(missing_ok=True)
        else: amphetamine.write_text(state)
        (case / 'value').write_text('1')
        p = helper(); p.stdout.readline()
        assert end(p) == 0, state
        kept = '1' if state == 'true,true' else '0'
        assert read(case / 'value') == kept, f'restore state {state}'
        # Enabling protection is independent of Amphetamine, including query failure.
        (case / 'value').write_text('0')
        p = helper(); p.stdout.readline()
        assert read(case / 'value') == '1', f'enable state {state}'
        end(p)
        assert read(case / 'value') == kept, f'EOF restore state {state}'
    print('PASS all Amphetamine states / query failure / unconditional enable', flush=True)
    (case / 'amphetamine').unlink()
    (case / 'value').write_text('0')
    p = helper(); p.stdout.readline()
    (case / 'amphetamine').write_text('true,true')
    end(p)
    assert read(case / 'value') == '1', 'did not respect Amphetamine started after launch'
    (case / 'amphetamine').unlink(); (case / 'value').write_text('0')
    print('PASS Amphetamine started during a lease', flush=True)
    # A second lease waits until the first has finished restoring.
    first = helper(); first.stdout.readline()
    second = helper(); time.sleep(1)
    assert second.poll() is None and read(case / 'value') == '1'
    end(first)
    assert second.stdout.readline() == b'active\n' and read(case / 'value') == '1', 'second lease not applied after first'
    assert end(second) == 0 and read(case / 'value') == '0'
    print('PASS second lease waits for the first to restore', flush=True)
    # Whoever sets the value back to 0 during a lease, it is re-applied.
    p = helper(); p.stdout.readline()
    (case / 'value').write_text('0')
    wait(lambda: read(case / 'value') == '1', 'reset during a lease not re-applied', timeout=8)
    assert p.stdout.readline() == b'active\n'
    (case / 'fail').touch(); (case / 'value').write_text('0')
    assert p.stdout.readline() == b'error\n', 're-apply failure not reported'
    (case / 'fail').unlink()
    assert p.stdout.readline() == b'active\n', 're-apply recovery not reported'
    end(p)
    assert read(case / 'value') == '0'
    print('PASS reset during a lease re-applied / failure reported', flush=True)
finally:
    if p.poll() is None: p.kill(); p.wait()

if '--watchdog-only' in sys.argv:
    sys.exit(0)

case = root / 'app'
case.mkdir()
(case / 'value').write_text('0')
(case / 'state.json').write_text('{"projects":[],"tabs":[]}')
env = dict(os.environ, VHOSTTY_SUPPORT_DIR=str(case), VHOSTTY_DEBUG_SNAPSHOT=str(case),
           VHOSTTY_SLEEP_TEST_DIR=str(case))
log = (case / 'app.log').open('w')
app = None

def start():
    global app
    (case / 'alert.txt').unlink(missing_ok=True)
    (case / 'state.txt').unlink(missing_ok=True)
    app = subprocess.Popen([str(binary / 'Vhostty')], env=env, stdout=log, stderr=log)
    wait(lambda: (case / 'state.txt').exists(), 'app debug driver did not start')

def stop():
    if app and app.poll() is None:
        app.terminate(); app.wait(timeout=20)

def button(title):
    previous = read(case / 'alert.txt')
    titles = previous.splitlines()
    index = next(i for i, t in enumerate(titles) if t in title)
    (case / 'input.txt').write_text(f'alertbutton {index}\n')
    wait(lambda: not (case / 'input.txt').exists(), 'alert action not consumed')
    wait(lambda: read(case / 'alert.txt') != previous, 'alert action did not complete')
    time.sleep(.3)

def prompt():
    wait(lambda: any(x in read(case / 'alert.txt') for x in ['Don’t Allow', '不允许']), 'onboarding did not appear')

try:
    start(); prompt()
    (case / 'authorization-result').write_text('cancel')
    button(['Allow', '允许'])
    time.sleep(2); stop()
    assert not (case / 'sleep-declined').exists()
    start(); prompt()
    print('PASS authorization cancellation reprompts on restart', flush=True)
    button(['Don’t Allow', '不允许']); stop()
    assert (case / 'sleep-declined').exists()
    start(); time.sleep(2)
    assert read(case / 'alert.txt') == ''
    stop(); print('PASS explicit refusal persists', flush=True)
    (case / 'sleep-declined').unlink()
    start(); prompt()
    (case / 'authorization-result').write_text('fail')
    button(['Allow', '允许'])
    wait(lambda: any(x in read(case / 'sleep-menu.txt') for x in ['Not Authorized', '未授权']), 'failure menu status missing')
    assert read(case / 'alert.txt') == '', 'failure opened a modal alert'
    stop()
    start(); prompt()
    print('PASS failed authorization reprompts', flush=True)
    (case / 'authorization-result').write_text('success')
    button(['Allow', '允许'])
    wait(lambda: (case / 'authorized').exists(), 'authorization did not succeed')
    stop()
    assert (case / 'authorized').exists()
    assert not (case / 'sleep-declined').exists()
    start(); time.sleep(2)
    assert read(case / 'alert.txt') == ''
    stop()
    (case / 'authorized').unlink()
    start(); prompt()
    print('PASS permission-based startup / revoked permission reprompts; no enabled flag', flush=True)
finally:
    stop(); log.close()

# Exercise the app's real terminal-title -> task status -> watchdog path.
# All shells, agents, HOME, project and input are isolated fixtures.
import json
import re
import uuid
case = root / 'terminal'
case.mkdir()
home = case / 'home'; home.mkdir()
bin_dir = case / 'bin'; bin_dir.mkdir()
project = case / 'project'; project.mkdir()
(home / '.zshenv').write_text(f'export PATH="{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin"\nunsetopt GLOBAL_RCS\n')
agent = bin_dir / 'codex'
agent.write_text('''#!/bin/sh
printf '\\033]0;Sleep fixture\\007'
while IFS= read -r line; do
    case "$line" in
        busy) printf '\\033]0;⠋ Sleep fixture\\007' ;;
        idle) printf '\\033]0;Sleep fixture\\007' ;;
    esac
done
''')
agent.chmod(0o755)
for name in ['claude', 'gh']:
    path = bin_dir / name; path.write_text('#!/bin/sh\nexit 1\n'); path.chmod(0o755)
(case / 'value').write_text('0'); (case / 'authorized').touch()
(case / 'state.json').write_text(json.dumps({'projects': [{'id': str(uuid.uuid4()), 'name': 'Sleep fixture', 'path': str(project), 'expanded': True}], 'tabs': []}))
env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
           CODEX_HOME=str(home / '.codex'), VHOSTTY_SUPPORT_DIR=str(case),
           VHOSTTY_DEBUG_SNAPSHOT=str(case), VHOSTTY_SLEEP_TEST_DIR=str(case))
log = (case / 'app.log').open('w')
def drive(command):
    (case / 'input.txt').write_text(command + '\n')
    wait(lambda: not (case / 'input.txt').exists(), 'terminal debug command not consumed')
try:
    start()
    drive('new codex')
    wait(lambda: 'Sleep fixture' in read(case / 'state.txt') and '--- tab ' in read(case / 'state.txt'), 'fixture terminal missing')
    tab = re.search(r'--- tab ([0-9A-Fa-f-]+)', read(case / 'state.txt')).group(1)
    drive(f'to {tab}\ntext busy\nenter')
    wait(lambda: read(case / 'value') == '1', 'working terminal did not acquire sleep protection')
    drive(f'to {tab}\ntext idle\nenter')
    wait(lambda: read(case / 'value') == '0', 'idle terminal did not restore sleep', timeout=30)
    (case / 'value').write_text('1'); time.sleep(5)
    assert read(case / 'value') == '1', 'idle app overwrote an external setting'
    (case / 'value').write_text('0')
    drive(f'to {tab}\ntext busy\nenter')
    wait(lambda: read(case / 'value') == '1', 'second turn did not acquire')
    app.kill(); app.wait(timeout=10)
    # The terminal's shells must not hold the lease pipe open.
    wait(lambda: read(case / 'value') == '0', 'app force-quit did not release protection', timeout=5)
    print('PASS actual terminal title / idle / external setting kept / new turn / app SIGKILL recovery', flush=True)
finally:
    stop(); log.close()

if '--skip-starting' in sys.argv:
    sys.exit(0)
# A card stuck in Starting stops counting after two minutes (plus the 15 s grace).
(case / 'value').write_text('0')
(case / 'state.json').write_text(json.dumps({'projects': [{'id': str(uuid.uuid4()), 'name': 'Sleep fixture', 'path': str(project), 'expanded': True}], 'tabs': []}))
log = (case / 'app.log').open('a')
try:
    start()
    drive('new codex')
    wait(lambda: read(case / 'value') == '1', 'starting card did not acquire')
    wait(lambda: read(case / 'value') == '0', 'stuck starting card kept the Mac awake', timeout=150)
    print('PASS stuck Starting card released', flush=True)
finally:
    stop(); log.close()
