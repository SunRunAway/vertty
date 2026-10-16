#!/usr/bin/env python3
"""Click/search time zones in a scratch app; never start an agent session."""
import json
import os
from pathlib import Path
import re
import tempfile
import time
import uuid
import testapp

root = Path(tempfile.mkdtemp(dir='/private/tmp', prefix='vertty-timezones-'))
support, snap, project, home = [root / name for name in ('support', 'snapshot', 'project', 'home')]
for path in (support, snap, project, home):
    path.mkdir()
project_id, task_id = [str(uuid.uuid4()).upper() for _ in range(2)]
(support / 'state.json').write_text(json.dumps({'projects': [
    {'id': project_id, 'name': 'Timezone fixture', 'path': str(project), 'expanded': True}
], 'tabs': []}))
(support / 'schedules.json').write_text(json.dumps({'tasks': [
    {'id': task_id, 'projectID': project_id, 'kind': 'codex', 'name': '09:30 timezone test',
     'prompt': 'Do not run. UI fixture only.', 'enabled': False, 'createdAt': '2026-10-15T00:00:00Z',
     'timing': {'repeatKind': 'once', 'hour': 9, 'minute': 30, 'weekdays': [],
                'year': 2099, 'month': 1, 'day': 15}}
], 'runs': []}))
env = dict(os.environ, VERTTY_SUPPORT_DIR=str(support), VERTTY_DEBUG_SNAPSHOT=str(snap), CODEX_HOME=str(home))


def state():
    path = snap / 'state.txt'
    return path.read_text() if path.exists() else ''


def wait(check):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.15)
    raise AssertionError('Timed out:\n' + state())


def drive(command):
    path = snap / 'input.txt'
    path.write_text(command + '\n')
    wait(lambda: not path.exists())


def popover(y=624):
    width = float(re.search(r'windowSize=([\d.]+),', state())[1])
    drive(f'postclick {width - 80} {y}')
    match = wait(lambda: re.search(r'window=(\d+) class=\S*Popover\S*', state()))
    return match[1]


def unchanged(zone):
    wait(lambda: f'draftTiming=9:30 date=2099-1-15 timezone={zone}' in state())


def saved():
    return json.loads((support / 'schedules.json').read_text())['tasks'][0]['timing']


print(f'Scratch artifacts: {root}', flush=True)
app = testapp.launch(env, str(root / 'app.log'))
try:
    wait(lambda: 'windowSize=' in state())
    drive('schedule ' + task_id)
    unchanged('local')
    window = popover()
    drive(f'windowclick {window} 120 100')  # New York, first region.
    unchanged('America/New_York')
    wait(lambda: 'dirty=true' in state())
    drive('panelsave')
    wait(lambda: 'dirty=false' in state())
    assert saved()['timeZoneID'] == 'America/New_York'
    drive('closepanel')
    drive('schedule ' + task_id)
    unchanged('America/New_York')
    print('PASS select, save and reopen: 09:30 and the date stay unchanged', flush=True)

    window = popover()
    drive(f'windowclick {window} 120 24')  # Search field.
    drive(f'windowtext {window} Tokyo')
    drive(f'windowclick {window} 120 100')
    unchanged('Asia/Tokyo')
    drive('panelcancel')
    unchanged('America/New_York')
    assert saved()['timeZoneID'] == 'America/New_York'
    print('PASS search Tokyo, cross-date zone change, and cancel', flush=True)

    window = popover()
    drive(f'windowclick {window} 120 60')  # Follow System.
    unchanged('local')
    drive('panelsave')
    wait(lambda: 'dirty=false' in state())
    assert 'timeZoneID' not in saved() and saved()['hour'] == 9 and saved()['minute'] == 30
    print('PASS reset to system zone and persist the original wall-clock fields', flush=True)

    drive('closepanel')
    drive('newschedule')
    wait(lambda: 'panel=new' in state())
    before = re.search(r'draftTiming=(.*) timezone=', state())[1]
    window = popover()  # Weekly has a Days row in place of Date, same position.
    drive(f'windowclick {window} 120 100')
    wait(lambda: f'draftTiming={before} timezone=America/New_York' in state())
    drive('panelcancel')
    wait(lambda: 'panel=-' in state())
    assert len(json.loads((support / 'schedules.json').read_text())['tasks']) == 1
    print('PASS new-task form uses the same zone picker without changing time', flush=True)
finally:
    app.terminate()
    app.wait(timeout=10)
