import copy,json,sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Backend'))
from presentations import Presentations,validate_spec,digest
class PresentationTests(unittest.TestCase):
 def spec(self):return {'brief':{'audience':'Team','purpose':'Explain','language':'en'},'expected_slide_count':1,'slides':[{'title':'Subject','purpose':'Overview','layout':'points','points':['One clear point']}]}
 def test_brief_and_exact_count_required(self):
  for edit in ({'brief':{}},{'expected_slide_count':2},{'template':'source.pptx'}):
   with self.assertRaises(ValueError):validate_spec({**self.spec(),**edit})
 def test_density_and_chart_data_fail_closed(self):
  spec=self.spec();spec['slides'][0]['points']=['x']*5
  with self.assertRaises(ValueError):validate_spec(spec)
  spec['slides'][0].update(layout='chart',chart={'categories':['A'],'series':[{'name':'value','values':[float('nan')]}]})
  with self.assertRaises(ValueError):validate_spec(spec)
 def test_review_response_not_a_truthy_string(self):
  with self.assertRaises(ValueError):Presentations.verdict({'passed':'yes','issues':[]})
  self.assertFalse(Presentations.verdict({'passed':True,'issues':['clipped title']})['passed'])
 def test_review_required_and_changed_draft_rejected(self):
  with tempfile.TemporaryDirectory() as d:
   class Cap:
    workspace=Path(d)
    def path(self,n):return self.workspace/n
    def artifact(self,p):return str(p)
    def emit(self,*a,**kw):pass
   p=Presentations(Cap());out,base=p.folder('deck.pptx');folder=base/'draft';folder.mkdir(parents=True)
   (folder/'draft.pptx').write_bytes(b'fixture');(folder/'slide-01.png').write_bytes(b'preview')
   m={'name':'deck.pptx','folder':str(folder),'sha256':digest(folder/'draft.pptx'),'spec':self.spec(),'structural':{'errors':[]},'reviews':[],'preview_hashes':{'slide-01.png':digest(folder/'slide-01.png')}}
   (base/'manifest.json').write_text(json.dumps(m))
   with self.assertRaises(ValueError):p.finalize({'name':'deck.pptx'})
   calls=[]
   def vision(image,question):calls.append(image);return {'passed':True,'issues':[]}
   p.review({'name':'deck.pptx'},vision)
   self.assertEqual(len(calls),2);self.assertIsNone(calls[-1])
   p.finalize({'name':'deck.pptx'});self.assertEqual(out.read_bytes(),b'fixture')
   (folder/'draft.pptx').write_bytes(b'changed')
   with self.assertRaises(ValueError):p.finalize({'name':'deck.pptx'})
 def test_failed_review_never_delivers(self):
  self.assertFalse(Presentations.verdict('{"passed":false,"issues":["overlap"]}')['passed'])
if __name__=='__main__':unittest.main()
