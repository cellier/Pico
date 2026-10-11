import json,sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Backend'))
from presentation_styles import StyleLibrary,ROOT,catalog,selected_style,validate_design,fit_design,contrast_ratio
D={'ink':'#FFFFFF','paper':'#101010','accent':'#FF3333','muted':'#CCCCCC','composition':'stage','heading_family':'sans','title_size':54,'cover_size':80,'body_size':28,'margin':72,'cover_invert':False,'signature':'large type','asset_guidance':'none','adaptations':'font fallback','avoid':'dense prose'}
class StyleTests(unittest.TestCase):
 def test_catalog_is_complete_and_portable(self):
  entries=catalog();self.assertEqual(len(entries),155);self.assertEqual(len({s['id'] for s in entries}),155)
  for s in entries:
   for f in [s['source']]+s['previews']:
    p=(ROOT/f).resolve();self.assertTrue(p.is_relative_to(ROOT.resolve()));self.assertTrue(p.is_file())
 def test_explicit_style_resolves_source_and_preview(self):
  with tempfile.TemporaryDirectory() as d:
   calls=[]
   def complete(q):calls.append(q);return D
   r=StyleLibrary(d,complete).run({'style_id':'PYClxCEx'})
   self.assertEqual(len(calls),1);self.assertTrue(r['selected']);self.assertTrue((Path(d)/r['style']['preview']).exists())
   self.assertEqual(selected_style(d,'PYClxCEx')['design']['paper'],D['paper'])
 def test_recommend_does_not_select(self):
  with tempfile.TemporaryDirectory() as d:
   response={'recommended':'PYClxCEx','candidates':[{'style_id':x,'reason':'fits'} for x in ('PYClxCEx','uu2GmD9M','nsvGrXIj')]}
   r=StyleLibrary(d,lambda _:response).run({'prompt':'Show options','mode':'recommend'})
   self.assertFalse(r['selected']);self.assertEqual(len(r['candidates']),3)
   with self.assertRaises(ValueError):selected_style(d,'PYClxCEx')
 def test_invalid_style_and_tokens_fail_closed(self):
  with tempfile.TemporaryDirectory() as d:
   lib=StyleLibrary(d,lambda _:D)
   with self.assertRaises(ValueError):lib.run({'style_id':'../../oops'})
   for edit in ({'paper':'white'},{'title_size':float('nan')},{'composition':'invented'}):
    with self.assertRaises(ValueError):validate_design({**D,**edit})
 def test_source_tokens_adapt_to_readable_output(self):
  d=fit_design({**D,'paper':'#FFFFFF','muted':'#F5F5F5','title_size':88,'signature':['one','two']})
  self.assertEqual(d['title_size'],64);self.assertIn('stage composition',d['signature'])
  self.assertGreaterEqual(contrast_ratio(d['muted'],d['paper']),4.5)
  self.assertGreaterEqual(contrast_ratio(d['ink'],d['paper']),4.5)
 def test_semantic_auto_uses_request_and_saves_choice(self):
  with tempfile.TemporaryDirectory() as d:
   calls=[]
   def complete(q):
    calls.append(q)
    return {'recommended':'nsvGrXIj','candidates':[{'style_id':x,'reason':'fits'} for x in ('PYClxCEx','uu2GmD9M','nsvGrXIj')]} if len(calls)==1 else D
   r=StyleLibrary(d,complete).run({'prompt':'technical comparison'})
   self.assertEqual(r['style']['style_id'],'nsvGrXIj');self.assertIn('technical comparison',calls[0]);self.assertIn('Benchmark',calls[1])
if __name__=='__main__':unittest.main()
