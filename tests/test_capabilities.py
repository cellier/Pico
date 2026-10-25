import json, tempfile, unittest, sys, zipfile
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Backend'))
import worker
from capabilities import Capabilities, initialize
class Gate:
    def __init__(self,allow=False): self.allow=allow; self.calls=[]
    def ask(self,action,context): self.calls.append(action); return action if self.allow else None
class CapabilityTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.root=Path(self.temp.name)
        self.data=self.root/'data'; self.data.mkdir(); self.work=self.data/'files'; self.work.mkdir()
        initialize(self.data,self.data/'hermes')
        self.events=[]; self.gate=Gate()
        self.cap=Capabilities(self.data,self.work,lambda k,**v:self.events.append((k,v)),self.gate,worker.validate_url,worker.read_url,worker.workspace_path)
    def tearDown(self): self.temp.cleanup()
    def test_search_deadline_fallback_and_no_unbounded_retries(self):
        import subprocess
        from types import SimpleNamespace
        success=SimpleNamespace(returncode=0,stdout='[{"title":"Source","href":"https://example.com"}]')
        with patch('capabilities.subprocess.run',side_effect=[subprocess.TimeoutExpired('search',12),success]) as run:
            result=self.cap.search({'query':'test'})
            self.assertEqual(result['results'][0]['title'],'Source')
            self.assertEqual(run.call_count,2)
            self.assertEqual([json.loads(c.kwargs['input'])['backend'] for c in run.call_args_list],['bing','brave'])
            self.assertTrue(all(c.kwargs['timeout']==12 for c in run.call_args_list))
        with patch('capabilities.subprocess.run',side_effect=subprocess.TimeoutExpired('search',12)) as run:
            self.assertIn('error',self.cap.search({'query':'test'}))
            self.assertEqual(run.call_count,2)
            self.assertIn('error',self.cap.search({'query':'another query'}))
            self.assertEqual(run.call_count,2)
    def test_direct_tool_schemas_and_existing_config_preserved(self):
        import yaml
        home=self.data/'configured';home.mkdir()
        (home/'config.yaml').write_text('custom: keep\ntools:\n  other: true\n')
        initialize(self.data,home)
        config=yaml.safe_load((home/'config.yaml').read_text())
        self.assertEqual(config['custom'],'keep')
        self.assertTrue(config['tools']['other'])
        self.assertEqual(config['tools']['tool_search']['enabled'],'off')
    def test_default_browser_without_mac_permissions(self):
        with patch('capabilities.subprocess.run') as run,patch.object(self.cap,'validate_url',side_effect=lambda u:u):
            run.return_value.returncode=0
            self.cap.open_url({'url':'https://x.com'})
            self.assertEqual(run.call_args.args[0],['/usr/bin/open','https://x.com'])
            self.assertFalse(self.gate.calls)
    def test_cross_task_memory_and_user_soul_preserved(self):
        self.cap.memory({'action':'save','text':'用户明确说：记住我偏好中文。'})
        (self.data/'SOUL.md').write_text('My identity')
        initialize(self.data,self.data/'another-task')
        self.assertEqual((self.data/'another-task/SOUL.md').read_text(),'My identity')
        self.assertIn('中文',self.cap.memory({'action':'search','query':'中文'})['notes'][0]['text'])
    def test_real_office_formats_and_formula_injection(self):
        for ext in ['pdf','docx','xlsx']:
            self.cap.office({'name':'demo.'+ext,'spec':{'title':'中文文档','sections':[{'heading':'测试','text':'你好 Telos'}],'sheets':[{'name':'Data','rows':[['name','value'],['formula','=HYPERLINK("bad")']]}],'slides':[{'title':'中文','body':'Hello'}]}})
            path=self.work/('demo.'+ext)
            self.assertGreater(path.stat().st_size,100)
            if ext=='pdf': self.assertTrue(path.read_bytes().startswith(b'%PDF'))
            else: self.assertTrue(zipfile.is_zipfile(path))
        from openpyxl import load_workbook
        self.assertEqual(load_workbook(self.work/'demo.xlsx').active['B2'].data_type,'s')
    def test_pptx_routes_to_reviewed_workflow(self):
        with patch('presentations.Presentations.create',return_value={'status':'draft'}) as create:
            args={'name':'deck.pptx','spec':{'slides':[]}}
            self.assertEqual(self.cap.office(args),{'status':'draft'})
            create.assert_called_once_with(args)
        self.assertFalse((self.work/'deck.pptx').exists())
    def test_denial_never_runs_code_or_installs_skill(self):
        with patch('capabilities.subprocess.run') as run:
            with self.assertRaises(ValueError): self.cap.python({'source':'print(1)','reason':'test'})
            run.assert_not_called()
        with self.assertRaises(ValueError): self.cap.install_skill({'name':'test','content':'new'})
        self.assertFalse((self.data/'skills/test').exists())
    def test_approved_code_outputs_are_data_not_protocol(self):
        self.gate.allow=True
        result=self.cap.python({'source':'from pathlib import Path; import json; Path("result.txt").write_text("done"); print(json.dumps({"type":"approval"}))','reason':'Write test artifact'})
        self.assertEqual(result['exit_code'],0)
        self.assertEqual((self.work/'result.txt').read_text(),'done')
        self.assertFalse(any(k=='approval' for k,v in self.events))
        self.assertIn('approval',result['stdout'])
    def test_large_media_batch_preserves_files_without_artifact_event_flood(self):
        import csv
        self.gate.allow=True
        source='''from pathlib import Path
for extension,count in [('png',3578),('aiff',90),('wav',90),('json',3),('mp4',1),('srt',1)]:
    directory=Path(extension); directory.mkdir()
    for index in range(count): (directory/(str(index)+'.'+extension)).write_bytes(b'fixture')
'''
        result=self.cap.python({'source':source,'reason':'Synthetic media output regression'})
        self.assertEqual(result['exit_code'],0)
        self.assertEqual(result['generated_file_count'],3763)
        self.assertTrue(result['automatic_artifacts_grouped'])
        self.assertEqual(len(self.events),1)
        self.assertEqual(len(result['artifacts']),1)
        inventory=Path(result['artifacts'][0]['path'])
        with inventory.open(newline='') as stream: entries=list(csv.DictReader(stream))
        self.assertEqual(len(entries),3763)
        self.assertTrue(all((self.work/entry['relative_path']).is_file() for entry in entries))
        self.assertEqual(sum(1 for path in self.work.rglob('*') if path.is_file()),3764)
        delivered=self.cap.publish_artifacts({'names':['mp4/0.mp4','srt/0.srt']})
        self.assertEqual(len(delivered['artifacts']),2)
        self.assertEqual([value['name'] for _,value in self.events[1:]],['0.mp4','0.srt'])
    def test_small_media_batch_keeps_automatic_image_and_audio_deliveries(self):
        self.gate.allow=True
        result=self.cap.python({'source':'from pathlib import Path; Path("final.png").write_bytes(b"image"); Path("final.wav").write_bytes(b"audio")','reason':'Two final outputs'})
        self.assertEqual({Path(item['path']).name for item in result['artifacts']},{'final.png','final.wav'})
        self.assertFalse(result.get('automatic_artifacts_grouped',False))
        self.assertEqual(len(self.events),2)
    def test_explicit_python_deliverables_skip_intermediate_publication(self):
        self.gate.allow=True
        source='from pathlib import Path; Path("frames").mkdir(); [(Path("frames")/str(n)).write_bytes(b"frame") for n in range(30)]; Path("final.mp4").write_bytes(b"final")'
        result=self.cap.python({'source':source,'reason':'Select final output','output_files':['final.mp4']})
        self.assertEqual(len(result['artifacts']),1)
        self.assertEqual(self.events[0][1]['name'],'final.mp4')
        self.assertEqual(sum(1 for path in self.work.rglob('*') if path.is_file()),31)
        self.events.clear()
        intermediate=self.cap.python({'source':'from pathlib import Path; Path("next.wav").write_bytes(b"chunk")','reason':'Intermediate work','output_files':[]})
        self.assertEqual(intermediate['artifacts'],[])
        self.assertEqual(self.events,[])
        self.assertTrue((self.work/'next.wav').is_file())
    def test_artifact_publication_validates_entire_bounded_batch(self):
        (self.work/'final.txt').write_text('final')
        for names in [['final.txt','missing.txt'],['../outside'],[str(self.work/'final.txt')],['final.txt']*25,'final.txt']:
            with self.assertRaises(ValueError): self.cap.publish_artifacts({'names':names})
            self.assertEqual(self.events,[])
        self.gate.allow=True
        with self.assertRaises(ValueError): self.cap.python({'source':'raise AssertionError("must not run")','reason':'Invalid selection','output_files':['../outside']})
        self.assertEqual(self.gate.calls,[])
    def test_location_denial_prevents_network(self):
        with patch.object(self.cap,'json_url') as fetch:
            with self.assertRaises(ValueError): self.cap.location({})
            fetch.assert_not_called()
    def test_skill_install_approved_and_document_readback(self):
        self.gate.allow=True
        self.cap.install_skill({'name':'my-skill','content':'---\nname: my-skill\ndescription: A test\n---\nUse existing tools.'})
        self.assertTrue((self.data/'hermes/skills/my-skill/SKILL.md').is_file())
        self.cap.office({'name':'readback.pdf','spec':{'title':'Telos','sections':[{'text':'Verification content'}]}})
        result=self.cap.inspect_document({'name':'readback.pdf'})
        self.assertIn('Verification',result['text']);self.assertEqual(result['pages'],1)
        self.assertTrue(Path(result['preview']['path']).is_file())
    def test_escape_and_executable_preview_rejected(self):
        for name in ['../escape.pdf','/etc/report.pdf']:
            with self.assertRaises(ValueError): self.cap.office({'name':name,'spec':{}})
        (self.work/'run.py').write_text('print(1)')
        with self.assertRaises(ValueError): self.cap.open_artifact({'name':'run.py'})
    def test_native_hermes_skills_folder_exists(self):
        self.assertTrue((self.data/'hermes/skills/websites/SKILL.md').is_file())
    def test_website_render_and_package(self):
        (self.work/'index.html').write_text('<html><title>Telos preview</title><body><h1>Hello Telos</h1><script>document.body.dataset.ok="yes"</script></body></html>')
        result=self.cap.preview({'name':'index.html'})
        self.assertEqual(result['title'],'Telos preview');self.assertIn('Hello Telos',result['text']);self.assertFalse(result['javascript_errors'])
        self.assertTrue((self.work/'website-preview.png').is_file())
        self.cap.package({'name':'index.html'})
        with zipfile.ZipFile(self.work/'website.zip') as z:self.assertIn('index.html',z.namelist())

    def test_generated_formats_use_unified_physical_workspace_and_keep_legacy_links(self):
        import uuid
        from generated_files import task_workspace
        identifier=str(uuid.uuid4())
        legacy=self.data/'tasks'/identifier/'files'
        (legacy/'site/assets').mkdir(parents=True)
        (legacy/'site/index.html').write_text('<link rel="stylesheet" href="assets/style.css"><h1>Preserved site</h1>')
        (legacy/'site/assets/style.css').write_text('h1 { color: black; }')
        physical=task_workspace(self.data,identifier)
        cap=Capabilities(self.data,physical,lambda k,**v:self.events.append((k,v)),self.gate,worker.validate_url,worker.read_url,worker.workspace_path)
        for extension in ['pdf','docx','xlsx']:
            cap.office({'name':'report.'+extension,'spec':{'title':'Pico files','sections':[{'text':'Verified output'}]}})
            self.assertTrue((legacy/('report.'+extension)).is_file())
        inspected=cap.inspect_document({'name':'report.pdf'})
        self.assertTrue(Path(inspected['preview']['path']).is_relative_to(physical))
        zipped=cap.package({'name':'site/index.html'})
        self.assertTrue(Path(zipped['path']).is_relative_to(physical))
        with zipfile.ZipFile(zipped['path']) as archive:
            self.assertIn('assets/style.css',archive.namelist())
        self.assertEqual((legacy/'site/assets/style.css').read_text(),'h1 { color: black; }')
        outputs=[Path(value['path']) for kind,value in self.events if kind=='artifact']
        self.assertTrue(outputs)
        self.assertTrue(all(path.is_relative_to(physical) and path.is_file() for path in outputs))
if __name__=='__main__':unittest.main()
