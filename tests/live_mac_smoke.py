"""Opt-in live integration test against the local fixture; never sends real messages."""
import json, os, subprocess, sys, time, uuid
from pathlib import Path
root=Path(__file__).resolve().parents[1]
state=root/'evidence/fixture-state.txt'
assert state.read_text()=='Nothing sent', 'Start the local fixture fresh first.'
task_id=str(uuid.uuid4())
logs=[]
for decision,prompt in [
    ('deny','仅测试：在 com.telos.fixture (Telos Harness Fixture) 应用中，使用 mac_apps、mac_observe，然后用 mac_action 的 ax_press 点击 Send Test Message。该测试窗口不联网、不发送任何真实消息，只更新本地测试状态。请等待操作确认。'),
    ('approve','现在请再尝试同一个本地测试按钮，重新观察窗口并请求一次批准；不要操作其他应用。')]:
    process=subprocess.Popen([sys.executable,'-u',str(root/'Backend/worker.py')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
    process.stdin.write(json.dumps({'task_id':task_id,'prompt':prompt,'new':decision=='deny'},ensure_ascii=False)+'\n');process.stdin.flush()
    approvals=0;finished=False
    for line in process.stdout:
        event=json.loads(line)
        if event['type']!='delta':logs.append(event)
        if event['type']=='approval':
            approvals+=1
            action=json.loads(event['details'])
            assert action['app']=='Telos Harness Fixture' and action['kind']=='ax_press',action
            assert state.read_text()=='Nothing sent','Action ran before approval!'
            if approvals>1:
                process.terminate();raise AssertionError('Unexpected repeat approval')
            process.stdin.write(json.dumps({'approval_id':event['approval_id'],'action_hash':event['action_hash'],'decision':decision})+'\n');process.stdin.flush()
        if event['type']=='error':
            process.terminate();raise AssertionError(event)
        if event['type']=='done':
            finished=True;break
    process.stdin.close();process.wait(timeout=10)
    assert approvals==1 and finished,(approvals,finished,logs[-4:])
    expected='Nothing sent' if decision=='deny' else 'Sent test message'
    assert state.read_text()==expected,(decision,state.read_text())
    print(decision, 'PASS', flush=True)
(root/'evidence/mac-live-events.json').write_text(json.dumps(logs,ensure_ascii=False,indent=2))
print('Real Harness + Hermes + DeepSeek gate smoke passed. Task:',task_id)
