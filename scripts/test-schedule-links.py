#!/usr/bin/env python3
"""Command-click task links in a scratch terminal: a plain-text URL, and an
OSC 8 link while the app captures the mouse, as Claude Code's full-screen TUI
does. The task panel opens beside the session, which stays on screen. Other
links under mouse capture stay the app's: it gets the click."""
import json
import os
from pathlib import Path
import tempfile
import time
import uuid
import testapp

# What the fixture agent prints on its first line: the escapes to turn mouse
# capture on, and the link.
CAPTURE = r'\033[?1049h\033[?1000h\033[?1002h\033[?1003h\033[?1006h'
CASES = {
    'plain-text URL': ('', '{url}', True),
    'OSC 8 link under mouse capture': (CAPTURE, r'\033]8;;{url}\007Open the clicked task here\033]8;;\007', True),
    'https link under mouse capture': (CAPTURE, r'\033]8;;https://example.com/\007Open the example page\033]8;;\007', False),
}


def run(name, setup, text, ours):
    root = Path(tempfile.mkdtemp(dir='/private/tmp', prefix='vhostty-links-'))
    home, project, support, snap, bins = [root / p for p in ('home', 'project', 'support', 'snap', 'bin')]
    for p in (home, project, support, snap, bins, home / '.codex'):
        p.mkdir(parents=True, exist_ok=True)
    pid, tid, task = [str(uuid.uuid4()).upper() for _ in range(3)]
    url = 'vhostty://schedule/' + task
    (home / '.zshenv').write_text(f'export PATH="{bins}:/usr/bin:/bin:/usr/sbin:/sbin"\nunsetopt GLOBAL_RCS\n')
    agent = bins / 'codex'
    # The terminal echoes what it sends the agent, so a reported click shows on screen.
    agent.write_text('#!/bin/sh\nprintf "' + setup + r'\033[2J\033[H' + text.format(url=url)
                     + r'\n\nREADY\n"' + '\nexec cat > /dev/null\n')
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
        wait(lambda: 'READY' in state())
        # The terminal starts at the right of the 300pt project sidebar, below the title strip.
        # Click well inside the first line's link, not the title or task list.
        (snap / 'input.txt').write_text(f'to {tid}\ncmdclick 420 50\n')
        if ours:
            wait(lambda: f'panel={task}' in state())
            assert 'schedulesShown=false' in state(), state()
            time.sleep(.5)
            assert '[<0;' not in state(), 'the app got the click: ' + state()
            print(f'PASS Command-click on the {name} opens its task panel beside the session', flush=True)
        else:
            wait(lambda: '[<0;' in state())
            assert 'panel=-' in state(), state()
            print(f'PASS Command-click on an {name} goes to the app', flush=True)
    finally:
        app.terminate()
        app.wait(timeout=10)


for name, (setup, text, ours) in CASES.items():
    run(name, setup, text, ours)
