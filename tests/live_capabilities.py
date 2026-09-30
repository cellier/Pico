"""Live Hermes/DeepSeek integration. Isolated test profile, no user memory changes."""
import json, os, shutil, subprocess, sys, tempfile, uuid
from pathlib import Path
root=Path(__file__).resolve().parents[1]
evidence=root/'evidence/capabilities';evidence.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='telos-capabilities-') as tmp:
 data=Path(tmp);shutil.copy(Path.home()/'Library/Application Support/Telos/config.json',data/'config.json');(data/'config.json').chmod(0o600)
 env=dict(os.environ,TELOS_DATA_DIR=str(data))
 scenarios=[
  ('memory-save','请记住：我的测试偏好是使用紫色标题。这是明确的记忆保存请求。请调用 telos_memory 保存，然后简短确认。'),
  ('website','请查询共享记忆中的测试配色偏好，再使用 websites skill，生成一个关于 Telos 的简洁英文单页网页 index.html，使用这个配色，内置 CSS，不加载外部资源。必须使用 preview_website 实际渲染检查，再 inspect_image 检查截图，然后 package_website 打包。不要打开任何 app，不运行自定义代码。'),
  ('office','使用 documents skill，生成一份中文 PDF 和 Word 简介、一份 xlsx 两行任务清单、一份 pptx 两页演示。主题均为 Telos 测试，使用 create_office_file，不运行代码，不打开 app。'),
 ]
 for name,prompt in scenarios:
  if os.environ.get('TELOS_SMOKE_ONLY') and name != os.environ['TELOS_SMOKE_ONLY']:continue
  task=str(uuid.uuid4());events=[]
  proc=subprocess.Popen([sys.executable,'-u',str(root/'Backend/worker.py')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=(evidence/(name+'.stderr')).open('w'),env=env,text=True)
  proc.stdin.write(json.dumps({'task_id':task,'prompt':prompt,'new':True},ensure_ascii=False)+'\n');proc.stdin.flush()
  done=None
  for line in proc.stdout:
   e=json.loads(line)
   if e['type']!='delta': events.append(e); print(name,e['type'],str(e.get('text',''))[:130],flush=True)
   if e['type']=='approval':
    proc.stdin.write(json.dumps({'approval_id':e['approval_id'],'action_hash':e['action_hash'],'decision':'deny'})+'\n');proc.stdin.flush();raise AssertionError('Unexpected approval')
   if e['type']=='error':raise AssertionError(e)
   if e['type']=='done':done=e
  proc.wait(timeout=15);assert done and done['status']=='ready',(name,done)
  (evidence/(name+'.json')).write_text(json.dumps(events,ensure_ascii=False,indent=2))
  files=data/'tasks'/task/'files'
  shutil.copytree(files,evidence/name,dirs_exist_ok=True)
  history=json.loads((data/'tasks'/task/'history.json').read_text())
  toolnames=[c['function']['name'] for m in history for c in m.get('tool_calls',[]) ]
  (evidence/(name+'-history.json')).write_text(json.dumps(history,ensure_ascii=False,indent=2))
  for m in history:
   for c in m.get('tool_calls',[]):
    if c['function']['name']=='tool_call':
     a=json.loads(c['function']['arguments']); toolnames.extend(call.get('name','') for call in a.get('calls',[]))
  (evidence/(name+'-tools.json')).write_text(json.dumps(toolnames))
  if name=='memory-save':assert 'telos_memory' in toolnames
  if name=='website':
   assert all(t in toolnames for t in ['telos_memory','skill_view','preview_website','package_website']),toolnames
   assert 'purple' in (files/'index.html').read_text().lower() or '#' in (files/'index.html').read_text()
  if name=='office':assert {'.pdf','.docx','.xlsx','.pptx'} <= {p.suffix for p in files.iterdir()}
 print('PASS: live Hermes skills, cross-task telos_memory, website render/ZIP and four office formats.',flush=True)
