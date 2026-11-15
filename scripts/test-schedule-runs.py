#!/usr/bin/env python3
import datetime
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid
import testapp

root = Path(tempfile.mkdtemp(dir='/private/tmp', prefix='vertty-schedule-runs-'))
home, project, support, snap, bins, calls = [root / name for name in
    ('home', 'project', 'support', 'snap', 'bin', 'calls')]
for path in (home, project, support, snap, bins, calls, home / '.codex'):
    path.mkdir(parents=True, exist_ok=True)
project_id = str(uuid.uuid4()).upper()
fixture_state = {'projects': [{'id': project_id, 'name': 'Fixture', 'path': str(project), 'expanded': True}],
                 'tabs': []}
(support / 'state.json').write_text(json.dumps(fixture_state))
(home / '.zshenv').write_text(f'export HOME="{home}"\nexport CODEX_HOME="{home / ".codex"}"\nexport PATH="{bins}:/usr/bin:/bin:/usr/sbin:/sbin"\nunsetopt GLOBAL_RCS\n')
agent_source = '''import json, os, pathlib, signal, sqlite3, subprocess, sys, time, uuid
args = sys.argv[1:]
kind = pathlib.Path(sys.argv[0]).name
run = os.environ.get('VERTTY_SCHEDULE_RUN', '')
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
if kind == 'claude':
    flag = '--resume' if '--resume' in args else '--session-id'
    session = args[args.index(flag) + 1]
    encoded = ''.join(c if c.isascii() and c.isalnum() else '-' for c in os.getcwd())
    transcript = root / 'home/.claude/projects' / encoded / (session + '.jsonl')
    transcript.parent.mkdir(parents=True, exist_ok=True)
    transcript.write_text(json.dumps({'type': 'assistant', 'cwd': os.getcwd(), 'sessionId': session}) + '\\n')
else:
    session = args[-1] if args[0] == 'resume' else str(uuid.uuid4())
    with sqlite3.connect(root / 'home/.codex/state_5.sqlite') as db:
        db.execute("INSERT OR REPLACE INTO threads VALUES (?, ?, 'Fixture', 'Fixture', '', ?, '', 0, 'cli', 'user', 'fixture', '')",
                   (session, os.getcwd(), int(time.time())))
    print('\\033]0;' + session + '\\007', end='', flush=True)
record = {'args': args, 'session': session, 'tab': os.environ['VERTTY_TAB_ID'],
          'pid': os.getpid(), 'run': run, 'kind': kind}
(root / 'calls' / (str(uuid.uuid4()) + '.json')).write_text(json.dumps(record))
def hook(event):
    subprocess.run([os.environ['VERTTY_HOOK']], input=json.dumps({
        'hook_event_name': event, 'session_id': session, 'cwd': os.getcwd()}).encode(), check=True)
if run:
    if kind == 'claude':
        hook('SessionStart')
        hook('UserPromptSubmit')
    while not (root / ('finish-' + run)).exists():
        time.sleep(.1)
    if kind == 'claude':
        hook('Stop')
    else:
        with sqlite3.connect(root / 'home/.codex/thread_history_1.sqlite') as db:
            db.execute('INSERT INTO thread_items VALUES (?, ?, ?, ?, ?, ?)',
                       (session, run, 'userMessage', int(time.time() * 1000), 1,
                        json.dumps({'content': [{'text': args[-1]}]})))
            db.execute('INSERT INTO thread_items VALUES (?, ?, ?, ?, ?, ?)',
                       (session, run, 'agentMessage', int(time.time() * 1000), 2,
                        json.dumps({'phase': 'final_answer'})))
            db.execute('INSERT INTO thread_turns VALUES (?, ?, ?)', (session, run, 'completed'))
while True:
    signal.pause()
'''
for kind in ('claude', 'codex'):
    path = bins / kind
    path.write_text(f'#!{sys.executable}\n' + agent_source)
    path.chmod(0o755)
with sqlite3.connect(home / '.codex/state_5.sqlite') as db:
    db.execute('CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, name TEXT, title TEXT, git_branch TEXT, '
               'updated_at INTEGER, rollout_path TEXT, archived INTEGER, source TEXT, thread_source TEXT, '
               'preview TEXT, git_origin_url TEXT)')
with sqlite3.connect(home / '.codex/thread_history_1.sqlite') as db:
    db.execute('CREATE TABLE thread_items (thread_id TEXT, turn_id TEXT, item_type TEXT, '
               'created_at_ms INTEGER, rollout_ordinal INTEGER, item_json TEXT)')
    db.execute('CREATE TABLE thread_turns (thread_id TEXT, turn_id TEXT, status TEXT)')
env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
           CODEX_HOME=str(home / '.codex'), VERTTY_SUPPORT_DIR=str(support),
           VERTTY_DEBUG_SNAPSHOT=str(snap), VERTTY_SOCK=str(support / 'hook.sock'), FIXTURE_ROOT=str(root))
env.pop('VERTTY_TAB_ID', None)
cli = testapp.APP / 'Contents/MacOS/vertty-schedule'


def state():
    path = snap / 'state.txt'
    return path.read_text() if path.exists() else ''


def wait(check):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.15)
    raise AssertionError('Timed out:\n' + state())


def drive(*commands):
    path = snap / 'input.txt'
    path.write_text('\n'.join(commands) + '\n')
    wait(lambda: not path.exists())


def request(op, task=None, fields=None, ok=True):
    command = [str(cli), op]
    if task:
        command.append(task)
    for key, value in (fields or {}).items():
        command += ['--' + key, value]
    result = subprocess.run(command, env=env, cwd=project, text=True, capture_output=True)
    response = json.loads(result.stdout)
    assert response['ok'] == ok, response
    return response


def saved():
    return json.loads((support / 'schedules.json').read_text())


def invocations():
    return [json.loads(path.read_text()) for path in calls.glob('*.json')]


def panel(task, dirty=False):
    return f'schedulesShown=false panel={task} dirty={str(dirty).lower()}' in state()


print(f'Scratch artifacts: {root}', flush=True)
app = testapp.launch(env, str(root / 'app.log'))
try:
    wait(lambda: (support / 'hook.sock').exists() and 'schedulesShown=' in state())
    histories = []
    for kind in ('claude', 'codex'):
        task = request('create', fields={'name': kind + ' fixture', 'prompt': 'Only reply fixture.',
            'repeat': 'daily', 'time': '23:59', 'agent': kind})['task']['id']
        request('pause', task)
        previous = None
        for index in range(2):
            request('run', task)
            record = wait(lambda: next((r for r in invocations() if r['kind'] == kind and r['run'] and
                                       r['run'] not in {h['run'] for h in histories}), None))
            request('run', task, ok=False)
            assert '--resume' not in record['args'] and 'resume' not in record['args'], record
            if previous:
                assert record['session'] != previous['session'] and record['tab'] != previous['tab']
                os.kill(previous['pid'], 0)
            (root / ('finish-' + record['run'])).touch()
            wait(lambda: any(r['id'] == record['run'] and r['state'] == 'replied' and
                             r.get('sessionID') == record['session'] for r in saved()['runs']))
            assert next(t for t in saved()['tasks'] if t['id'] == task)['sessionID'] == record['session']
            assert 'selected: -' in state(), state()
            histories.append(dict(record, task=task))
            previous = record
        print(f'PASS {kind}: each run creates a new session/card, leaves the earlier agent alive, '
              'keeps background selection, records completion and rejects overlap', flush=True)

    for record in histories:
        drive('schedule ' + record['task'], 'openschedulerun ' + record['run'])
        wait(lambda: panel(record['task']) and 'selected: ' + record['tab'] in state())
    drive('panelname Unsaved fixture', 'openschedulerun ' + histories[-2]['run'])
    wait(lambda: panel(histories[-2]['task'], True) and 'draft=Unsaved fixture' in state())
    print('PASS history opens each original card and keeps the panel and unsaved draft', flush=True)

    app.terminate()
    app.wait(timeout=10)
    for record in invocations():
        try:
            os.kill(record['pid'], 15)
        except ProcessLookupError:
            pass
    data = saved()
    due_task = next(t for t in data['tasks'] if t['id'] == histories[0]['task'])
    due_task['enabled'] = True
    due_task['sessionID'] = 'missing-legacy-session'
    due_at = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=5)
    due_task['nextPlan'] = due_at.strftime('%Y-%m-%dT%H:%M:%SZ')
    due_task['timing'].update(hour=due_at.hour, minute=due_at.minute, timeZoneID='UTC')
    (support / 'schedules.json').write_text(json.dumps(data))
    (support / 'state.json').write_text(json.dumps(fixture_state))
    (snap / 'state.txt').unlink(missing_ok=True)
    app = testapp.launch(env, str(root / 'app.log'))
    wait(lambda: 'schedulesShown=' in state() and 'selected: -' in state())
    caught_up = wait(lambda: next((r for r in invocations() if r['run'] and
                                  r['run'] not in {h['run'] for h in histories}), None))
    assert caught_up['session'] not in {h['session'] for h in histories}
    assert '--resume' not in caught_up['args'] and 'resume' not in caught_up['args']
    (root / ('finish-' + caught_up['run'])).touch()
    wait(lambda: any(r['id'] == caught_up['run'] and r['state'] == 'replied' and
                     r['trigger'] == 'catchUp' for r in saved()['runs']))
    drive('tickschedules')
    assert len(saved()['runs']) == 5
    print('PASS automatic catch-up ignores a missing legacy session and does not repeat a claimed plan', flush=True)
    for record in (histories[0], histories[2]):
        drive('schedule ' + record['task'], 'openschedulerun ' + record['run'])
        wait(lambda: panel(record['task']) and f"session={record['session']} " in state())
        resumed = wait(lambda: next((r for r in invocations() if not r['run'] and
                                    r['session'] == record['session']), None))
        assert '--resume' in resumed['args'] or 'resume' in resumed['args'], resumed
    print('PASS closed historical sessions resume into new cards while the task panel stays open', flush=True)
finally:
    app.terminate()
    app.wait(timeout=10)
    for record in invocations():
        try:
            os.kill(record['pid'], 15)
        except ProcessLookupError:
            pass
