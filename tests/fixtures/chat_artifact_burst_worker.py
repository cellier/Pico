"""No-model NDJSON producer for native Chat artifact batching regression tests."""
import json
import os
import sys
import time
from pathlib import Path


def line(kind, **values):
    return json.dumps({'type': kind, **values}) + '\n'


request = json.loads(sys.stdin.readline())
assert request['mode'] == 'chat'
mode = request['prompt']
assert mode in ('burst done', 'burst error', 'burst stop', 'burst abrupt')
count = 3763
run_id = request['run_id'].lower()
directory = Path(os.environ['TELOS_DATA_DIR']) / 'burst-fixture-files' / run_id
directory.mkdir(parents=True, exist_ok=True)
# One actual tiny file makes these ordinary local file references; the test is
# about lifecycle metadata, not writing thousands of media binaries.
(directory / '0.dat').write_text('Private no-model artifact fixture')
events = [line('delta', text='Private burst output')]
for index in range(count):
    events.append(line('artifact', path=str(directory / (str(index) + '.dat')),
                       name='artifact-' + str(index) + '.dat'))
# Saving the same path again must update its metadata without duplicating it.
for index in (0, count // 2, count - 1):
    events.append(line('artifact', path=str(directory / (str(index) + '.dat')),
                       name='updated-artifact-' + str(index) + '.dat'))
if mode == 'burst done':
    events.append(line('done', text='Final burst result', status='ready', summary='Ready'))
elif mode == 'burst error':
    events.append(line('error', text='Deliberate burst error'))
elif mode == 'burst stop':
    events.append(line('phase', status='burst-ready-to-stop'))
sys.stdout.write(''.join(events))
sys.stdout.flush()
if mode == 'burst stop':
    time.sleep(30)
elif mode in ('burst error', 'burst abrupt'):
    sys.exit(1)
