#!/usr/bin/env python3
"""Verify the Enabled Agents menu, and the File menu it drives (⌘T starts the
agent last started in the project), in an isolated app with fake agents."""
import json
import os
from pathlib import Path
import tempfile
import time
import uuid
import testapp

root = Path(tempfile.mkdtemp(prefix='vertty-enabled-agents-', dir='/private/tmp'))
print(f'Scratch artifacts: {root}', flush=True)
(root / 'legacy').mkdir()
# A project and global default from before the setting must not matter.
projects = [dict(id=str(uuid.uuid4()), name='legacy', path=str(root / 'legacy'), expanded=True, defaultKind='codex')]
state_path = root / 'state.json'
state_path.write_text(json.dumps(dict(projects=projects, tabs=[], detectedKind='codex', newProjectKind='codex')))
home, bin_dir = root / 'home', root / 'bin'
for d in (home / '.codex', bin_dir):
    d.mkdir(parents=True)
for name in ('claude', 'codex'):
    (bin_dir / name).write_text('#!/bin/sh\nexec cat\n')
    (bin_dir / name).chmod(0o755)
(home / '.zshenv').write_text(f'export PATH="{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin"\nunsetopt GLOBAL_RCS\n')
env = dict(os.environ, VERTTY_SUPPORT_DIR=str(root), VERTTY_DEBUG_SNAPSHOT=str(root), HOME=str(home),
           CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home), CODEX_HOME=str(home / '.codex'))


def wait_for(check, what):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(.2)
    raise AssertionError(f'Timed out waiting for {what}')


def state():
    return json.loads(state_path.read_text())


def snapshot_has(expected):
    path = root / 'state.txt'
    return path.exists() and expected in path.read_text()


def command(text):
    (root / 'input.txt').write_text(text + '\n')
    wait_for(lambda: not (root / 'input.txt').exists(), 'the command to be read')


def new_session_items():
    lines = [l for l in (root / 'state.txt').read_text().splitlines() if l.startswith('new-session-menu: ')]
    return lines[0].split(': ', 1)[1].split(', ') if lines else []


def menus(agents, kinds):
    """The Enabled Agents items, and the File menu's New … Session items
    (titles may be localized, so only the agent names are checked)."""
    wait_for(lambda: snapshot_has('enabled-agents-menu: ' + agents + '\n'), 'agents menu ' + agents)
    def matches():
        items = new_session_items()
        return (len(items) == len(kinds) and all(k in i for k, i in zip(kinds, items))
                and items[0].endswith(' ⌘T'))
    wait_for(matches, f'File menu items for {kinds}')


app = testapp.launch(env, str(root / 'app.log'))
try:
    menus('Claude Code=true, Codex=true', ['Claude', 'Codex'])
    command('new codex')
    wait_for(lambda: state()['projects'][0].get('lastKind') == 'codex', 'Codex to be the last started')
    menus('Claude Code=true, Codex=true', ['Codex', 'Claude'])
    command('new')  # ⌘T
    wait_for(lambda: [t['kind'] for t in state()['tabs']] == ['codex', 'codex'], 'a second Codex session')
    command('new claude')
    wait_for(lambda: state()['projects'][0].get('lastKind') == 'claude', 'Claude to be the last started')
    menus('Claude Code=true, Codex=true', ['Claude', 'Codex'])
    command('toggleagent claude')
    wait_for(lambda: state().get('enabledKinds') == ['codex'], 'Claude to be turned off')
    menus('Claude Code=false, Codex=true (locked)', ['Codex'])
    command('new')  # The last started agent is off: the enabled one.
    wait_for(lambda: [t['kind'] for t in state()['tabs']][0] == 'codex' and len(state()['tabs']) == 4, 'a Codex session')
    command('toggleagent codex')  # The last one stays on.
    time.sleep(2)
    assert state().get('enabledKinds') == ['codex']
    command('toggleagent claude\ntoggleagent codex')
    wait_for(lambda: state().get('enabledKinds') == ['claude'], 'only Claude to be on')
    menus('Claude Code=true (locked), Codex=false', ['Claude'])
    command('toggleagent codex')
    wait_for(lambda: state().get('enabledKinds') == ['claude', 'codex'], 'both to be on')
    command('toggleagent claude')
    wait_for(lambda: state().get('enabledKinds') == ['codex'], 'only Codex to be on')
finally:
    app.terminate()
    app.wait(timeout=10)
(root / 'state.txt').unlink(missing_ok=True)
app = testapp.launch(env, str(root / 'restart.log'))
try:
    menus('Claude Code=false, Codex=true (locked)', ['Codex'])
finally:
    app.terminate()
    app.wait(timeout=10)
print('PASS: both on by default, toggling, the last agent stays on, ⌘T follows the last started agent, File menu items, persistence')
