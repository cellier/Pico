"""No-model fixture for the native Chat NDJSON lifecycle test."""
import json
import os
import sys
import time
from pathlib import Path


def emit(kind, **values):
    print(json.dumps({'type': kind, **values}), flush=True)


request = json.loads(sys.stdin.readline())
assert request['mode'] == 'chat'
output = Path(os.environ['TELOS_DATA_DIR']) / 'fixture-results' / (request['prompt'].replace(' ', '-') + '.md')
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text('Private local worker output')
emit('artifact', path=str(output), name=output.name)
emit('artifact', path=str(output), name=output.name)  # A repeated save is one output per reply.
if request['prompt'] == 'artifact only fixture':
    emit('done', text='', status='ready', summary='Ready')
    sys.exit(0)
if request['prompt'] == 'abrupt fixture':
    sys.exit(1)
emit('phase', status='working')
emit('delta', text='First ')
time.sleep(0.12)
emit('delta', text='second')
if request['prompt'] == 'stop fixture':
    time.sleep(30)
elif request['prompt'] == 'error fixture':
    emit('error', text='Deliberate fixture error')
    sys.exit(1)
else:
    emit('approval', approval_id='fixture', action_hash='exact-payload-hash', app='Local fixture',
         text='Approve one local test action', details='No external action', risk='action', expires_at=time.time()+30)
    response = json.loads(sys.stdin.readline())
    assert response == {'approval_id': 'fixture', 'action_hash': 'exact-payload-hash', 'decision': 'approve'}
    emit('approval_resolved', approval_id='fixture')
    emit('create_tasks', request_id='fixture-create', tasks=[{'title': 'Review fixture', 'instructions': 'Inspect the fixture result.'}])
    result = json.loads(sys.stdin.readline())
    assert result['request_id'] == 'fixture-create' and result['status'] == 'saved_not_started'
    assert len(result['tasks']) == 1
    emit('done', text='Final fixture result', status='ready', summary='Ready')
