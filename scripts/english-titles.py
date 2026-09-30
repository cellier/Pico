"""One-time migration for existing task titles. Run with the app closed."""
import json, os, sys, tempfile
from pathlib import Path
from openai import OpenAI
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'Backend'))
from worker import TITLE_INSTRUCTIONS
# Import worker redirects diagnostic output only; this script writes via sys.stderr.
data=Path.home()/'Library/Application Support/Telos'
path=data/'tasks.json'; original=path.read_bytes();tasks=json.loads(original)
config=json.loads((data/'config.json').read_text())
client=OpenAI(api_key=config['api_key'],base_url=config['base_url'],timeout=45,max_retries=1)
changes=[]
for t in tasks:
 if t['title'].isascii():continue
 result=client.chat.completions.create(model=config.get('model','deepseek-flash'),messages=[{'role':'system','content':TITLE_INSTRUCTIONS},{'role':'user','content':t['title']}],max_tokens=100,extra_body={'thinking':{'type':'disabled'}})
 title=(result.choices[0].message.content or '').strip().strip('"')
 if not title or any('\u4e00'<=c<='\u9fff' for c in title):raise ValueError('Title was not translated into English')
 changes.append({'id':t['id'],'before':t['title'],'after':title}); t['title']=title
if path.read_bytes()!=original:raise RuntimeError('Tasks changed while translating; no migration was written')
backup=data/'tasks.before-english-titles.json'
if not backup.exists():backup.write_bytes(original);backup.chmod(0o600)
temp=path.with_suffix('.titles.tmp');temp.write_text(json.dumps(tasks,ensure_ascii=False));temp.chmod(0o600);temp.replace(path)
(root/'evidence/english-titles.json').write_text(json.dumps(changes,ensure_ascii=False,indent=2))
print('Translated',len(changes),'existing task titles; other fields preserved.')
