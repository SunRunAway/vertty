#!/usr/bin/env python3
"""CRUD through MCP, saved-state failures, and task links in a scratch app."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid
import testapp

root = Path(tempfile.mkdtemp(dir='/private/tmp', prefix='vertty-schedule-'))
support, snapshot, project, home = [root / p for p in ('support', 'snapshot', 'project', 'codex')]
for p in (support, snapshot, project, home):
    p.mkdir()
(support / 'state.json').write_text(json.dumps({'projects': [
    {'id': str(uuid.uuid4()), 'name': 'Fixture', 'path': str(project), 'expanded': True}
], 'tabs': []}))
env = dict(os.environ, VERTTY_SUPPORT_DIR=str(support), VERTTY_DEBUG_SNAPSHOT=str(snapshot),
           VERTTY_SOCK=str(support / 'hook.sock'), CODEX_HOME=str(home))
env.pop('VERTTY_TAB_ID', None)
cli = testapp.APP / 'Contents/MacOS/vertty-schedule'


def wait(check):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(.2)
    raise AssertionError('timed out')


def state():
    p = snapshot / 'state.txt'
    return p.read_text() if p.exists() else ''


def drive(command):
    (snapshot / 'input.txt').write_text(command + '\n')
    wait(lambda: not (snapshot / 'input.txt').exists())


def rpc(method, params=None):
    request = {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params or {}}
    result = subprocess.run([str(cli), 'mcp'], input=json.dumps(request) + '\n',
                            capture_output=True, text=True, check=True, env=env, cwd=project)
    return json.loads(result.stdout)['result']


def call(name, args, ok=True):
    response = rpc('tools/call', {'name': name + '_scheduled_task', 'arguments': args})
    result = json.loads(response['content'][0]['text'])
    assert result['ok'] == ok and response['isError'] != ok, result
    return result


print(f'Scratch artifacts: {root}', flush=True)
app = testapp.launch(env, str(root / 'app.log'))
try:
    wait(lambda: (support / 'hook.sock').exists() and 'schedulesShown=' in state())
    assert 'You may include that URL as a Markdown link' in rpc('initialize')['instructions']
    descriptions = {t['name']: t['description'] for t in rpc('tools/list')['tools']}
    for verb in ('create', 'edit', 'delete'):
        assert 'you may share the link' in descriptions[verb + '_scheduled_task']
    fields = dict(name='Schedule API test', prompt='Only reply test complete.', repeat='once',
                  date=str(datetime.date.today() + datetime.timedelta(days=7)), time='23:59', agent='codex')
    created = call('create', fields)
    task_id, url = created['task']['id'], created['url']
    assert url == 'vertty://schedule/' + task_id == created['task']['url']
    assert created['task']['enabled'] and created['task']['nextRun']
    assert 'panel=-' in state() and 'schedulesShown=false' in state()
    saved = lambda: json.loads((support / 'schedules.json').read_text())['tasks']
    assert saved()[0]['id'] == task_id
    edited = call('edit', {'task_id': task_id, 'name': 'Updated'})
    assert edited['task']['name'] == 'Updated' and edited['url'] == url
    assert saved()[0]['name'] == 'Updated'
    call('edit', {'task_id': task_id, 'prompt': ''}, ok=False)
    assert saved()[0]['name'] == 'Updated'
    drive('openurl ' + url)
    wait(lambda: f'panel={task_id}' in state() and 'draft=Updated' in state())
    call('edit', {'task_id': task_id, 'name': 'Refreshed'})
    wait(lambda: 'draft=Refreshed' in state())
    drive('closepanel')
    drive('newschedule')
    wait(lambda: 'panel=new' in state())
    call('edit', {'task_id': task_id, 'name': 'While editing'})
    deleted = call('delete', {'task_id': task_id})
    assert deleted['task']['deleted'] and not deleted['task']['enabled'] and deleted['url'] == url
    assert 'panel=new' in state()
    assert saved()[0]['deletedAt']
    drive('openurl ' + url)
    wait(lambda: f'panel={task_id}' in state() and 'draft=While editing' in state())
    drive('closepanel')
    drive('openurl vertty://schedule/not-a-uuid')
    assert 'panel=-' in state()
    print('PASS direct CRUD, durable state, no automatic panels, links including deleted tasks', flush=True)

    # A failed atomic write must return an error and roll back the in-memory mutation.
    live = call('create', dict(fields, name='Survivor'))['task']['id']
    path = support / 'schedules.json'
    backup = support / 'schedules.backup'
    path.rename(backup)
    path.mkdir()
    try:
        call('create', dict(fields, name='Must not exist'), ok=False)
        call('edit', {'task_id': live, 'name': 'Must not change'}, ok=False)
        call('delete', {'task_id': live}, ok=False)
        shown = call('show', {'task_id': live})['task']
        assert shown['name'] == 'Survivor' and not shown['deleted']
        listed = rpc('tools/call', {'name': 'list_scheduled_tasks', 'arguments': {}})
        assert len(json.loads(listed['content'][0]['text'])['tasks']) == 1
    finally:
        path.rmdir()
        backup.rename(path)
    print('PASS persistence failures return errors and roll back all three mutations', flush=True)
finally:
    app.terminate()
    app.wait(timeout=10)
