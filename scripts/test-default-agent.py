#!/usr/bin/env python3
"""Verify the new-project default through the real menu in an isolated app."""
import json
import os
from pathlib import Path
import tempfile
import time
import uuid
import testapp

root = Path(tempfile.mkdtemp(prefix='vertty-default-agent-', dir='/private/tmp'))
print(f'Scratch artifacts: {root}', flush=True)
for name in ('legacy', 'explicit', 'new-codex', 'new-claude'):
    (root / name).mkdir()
projects = [dict(id=str(uuid.uuid4()), name=name, path=str(root / name), expanded=True,
                 **({'defaultKind': 'codex'} if name == 'explicit' else {}))
            for name in ('legacy', 'explicit')]
state_path = root / 'state.json'
state_path.write_text(json.dumps(dict(projects=projects, tabs=[], detectedKind='claude')))
env = dict(os.environ, VERTTY_SUPPORT_DIR=str(root), VERTTY_DEBUG_SNAPSHOT=str(root),
           VERTTY_DEFAULT_AGENT='codex')  # Removed setting must have no effect.


def wait_for(check):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(.2)
    raise AssertionError('Timed out waiting for expected state')


def state():
    return json.loads(state_path.read_text())


def menu_has(expected):
    path = root / 'state.txt'
    return path.exists() and expected in path.read_text()


def command(text):
    (root / 'input.txt').write_text(text + '\n')
    wait_for(lambda: not (root / 'input.txt').exists())


app = testapp.launch(env, str(root / 'app.log'))
try:
    wait_for(lambda: menu_has('Claude Code=true, Codex=false'))
    command('newprojectagent codex\naddproject ' + str(root / 'new-codex'))
    wait_for(lambda: state().get('newProjectKind') == 'codex' and len(state()['projects']) == 3)
    assert [p['defaultKind'] for p in state()['projects']] == ['claude', 'codex', 'codex']
    wait_for(lambda: menu_has('Claude Code=false, Codex=true'))
    command('newprojectagent claude\naddproject ' + str(root / 'new-claude'))
    wait_for(lambda: state().get('newProjectKind') == 'claude' and len(state()['projects']) == 4)
    assert [p['defaultKind'] for p in state()['projects']] == ['claude', 'codex', 'codex', 'claude']
    command('newprojectagent codex')
    wait_for(lambda: state().get('newProjectKind') == 'codex')
finally:
    app.terminate()
    app.wait(timeout=10)
(root / 'state.txt').unlink(missing_ok=True)
app = testapp.launch(env, str(root / 'restart.log'))
try:
    wait_for(lambda: menu_has('Claude Code=false, Codex=true'))
    command('addproject ' + str(root / 'new-claude'))
    time.sleep(2)
    assert len(state()['projects']) == 4
    assert [p['defaultKind'] for p in state()['projects']] == ['claude', 'codex', 'codex', 'claude']
finally:
    app.terminate()
    app.wait(timeout=10)
print('PASS: menu checkmarks, legacy defaults, new projects, persistence, duplicate projects, removed environment setting')
