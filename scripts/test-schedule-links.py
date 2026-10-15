#!/usr/bin/env python3
"""Click a plain-text task URL in a scratch terminal, through Ghostty's matcher."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid
import testapp

root = Path(tempfile.mkdtemp(dir='/private/tmp', prefix='vhostty-links-'))
home, project, support, snap, bins = [root / p for p in ('home', 'project', 'support', 'snap', 'bin')]
for p in (home, project, support, snap, bins, home / '.codex'):
    p.mkdir(parents=True, exist_ok=True)
pid, tid, task = [str(uuid.uuid4()).upper() for _ in range(3)]
url = 'vhostty://schedule/' + task
(home / '.zshenv').write_text(f'export PATH="{bins}:/usr/bin:/bin:/usr/sbin:/sbin"\nunsetopt GLOBAL_RCS\n')
agent = bins / 'codex'
agent.write_text('#!/bin/sh\nprintf "\\033[2J\\033[H%s\\n" "' + url + '"\nread answer\n')
agent.chmod(0o755)
(support / 'state.json').write_text(json.dumps({'projects': [
    {'id': pid, 'name': 'Fixture', 'path': str(project), 'expanded': True}],
    'tabs': [{'id': tid, 'projectID': pid, 'kind': 'codex', 'sessionID': str(uuid.uuid4()),
              'title': 'Link fixture', 'cwd': str(project)}], 'selectedTabID': tid}))
(support / 'schedules.json').write_text(json.dumps({'tasks': [
    {'id': task, 'projectID': pid, 'kind': 'codex', 'name': 'Clicked task', 'prompt': 'Hello',
     'enabled': False, 'createdAt': '2026-10-15T00:00:00Z',
     'timing': {'repeatKind': 'daily', 'hour': 9, 'minute': 0, 'weekdays': []}}], 'runs': []}))

def state():
    p = snap / 'state.txt'
    return p.read_text() if p.exists() else ''

def wait(check):
    end = time.monotonic() + 25
    while time.monotonic() < end:
        if check(): return
        time.sleep(.2)
    raise AssertionError(state())

env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
           CODEX_HOME=str(home / '.codex'), VHOSTTY_SUPPORT_DIR=str(support),
           VHOSTTY_DEBUG_SNAPSHOT=str(snap))
print('Scratch artifacts:', root, flush=True)
app = testapp.launch(env, str(root / 'app.log'))
try:
    wait(lambda: url in state())
    # The terminal starts at the right of the 300pt project sidebar, below the title strip.
    # Click well inside the first line's URL, not the title or task list.
    (snap / 'input.txt').write_text(f'to {tid}\ncmdclick 420 50\n')
    wait(lambda: f'panel={task}' in state())
    print('PASS Command-click on a plain-text task URL opens its task panel', flush=True)
finally:
    app.terminate()
    app.wait(timeout=10)
