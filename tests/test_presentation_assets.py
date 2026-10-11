import json,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
from PIL import Image,ImageDraw
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Backend'))
from presentation_assets import PresentationAssets,audit_assets,fingerprint,same_image,ImageHTML
class AssetsTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();root=Path(self.tmp.name)
  class Cap:
   workspace=root
   def path(self,n):return (self.workspace/n).resolve()
  self.cap=Cap();self.assets=PresentationAssets(self.cap,lambda *a:{'passed':True,'issues':[]})
  im=Image.new('RGB',(800,500),'white');d=ImageDraw.Draw(im);d.rectangle((60,30,540,390),fill='navy');d.ellipse((200,120,750,460),fill='red');im.save(root/'original.png');im.resize((640,400)).save(root/'compressed.jpg',quality=80)
  Image.new('RGB',(800,500),'green').save(root/'different.png')
 def tearDown(self):self.tmp.cleanup()
 def register(self,name,role='photo'):return self.assets.run({'action':'local','path':name,'role':role,'purpose':'fixture'})['asset']['path']
 def test_recompression_and_resize_detected(self):
  self.assertTrue(same_image(fingerprint(self.cap.path('original.png')),fingerprint(self.cap.path('compressed.jpg'))))
  self.assertFalse(same_image(fingerprint(self.cap.path('original.png')),fingerprint(self.cap.path('different.png'))))
 def test_cropped_photo_detected(self):
  with Image.open(self.cap.path('original.png')) as im:im.crop((80,50,720,450)).save(self.cap.path('crop.png'))
  self.assertTrue(same_image(fingerprint(self.cap.path('original.png')),fingerprint(self.cap.path('crop.png'))))
 def test_duplicate_photo_blocks_deck(self):
  a=self.register('original.png');b=self.register('compressed.jpg')
  with self.assertRaisesRegex(ValueError,'repeats'):audit_assets(self.cap,{'slides':[{'image':{'path':a}},{'image':{'path':b}}]})
 def test_distinct_photos_and_repeated_logo_allowed(self):
  a=self.register('original.png');b=self.register('different.png');logo=self.register('compressed.jpg','logo')
  self.assertEqual(len(audit_assets(self.cap,{'slides':[{'image':{'path':a}},{'image':{'path':b}}]})),2)
  self.assertEqual(len(audit_assets(self.cap,{'slides':[{'logo':{'path':logo}},{'logo':{'path':logo}}]})),2)
 def test_role_and_changed_bytes_fail_closed(self):
  a=self.register('original.png')
  with self.assertRaisesRegex(ValueError,'photo'):audit_assets(self.cap,{'slides':[{'logo':{'path':a}}]})
  Image.new('RGB',(800,500),'black').save(self.cap.path(a))
  with self.assertRaisesRegex(ValueError,'verify'):audit_assets(self.cap,{'slides':[{'image':{'path':a}}]})
 def test_wrong_subject_and_fabricated_candidate_rejected(self):
  self.assets.review=lambda *a:{'passed':False,'issues':['wrong brand']}
  self.assertEqual(self.assets.run({'action':'local','path':'original.png','purpose':'brand','role':'logo'})['status'],'rejected')
  with self.assertRaisesRegex(ValueError,'observed'):self.assets.run({'action':'fetch','candidate_id':'invented','purpose':'brand'})
 def test_processed_image_retains_source(self):
  self.cap.validate_url=lambda url:url
  r=self.assets.run({'action':'local','path':'original.png','role':'photo','purpose':'fixture','source_url':'https://example.com/original'})
  self.assertEqual(r['asset']['source_url'],'https://example.com/original')
 def test_page_resolves_relative_assets_without_executing_html(self):
  self.assets.request=lambda *a:(b'<img src="/a.png" alt="Product"><meta property="og:image" content="/b.jpg"><script>danger()</script>', 'text/html','https://example.com/page')
  r=self.assets.run({'action':'page','page_url':'https://example.com/page'})
  self.assertEqual([v['image_url'] for v in r['candidates']],['https://example.com/a.png','https://example.com/b.jpg'])
if __name__=='__main__':unittest.main()
