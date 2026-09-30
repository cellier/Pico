import sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Backend'))
from feeds import FeedRepository
class FeedTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.repo=FeedRepository(self.temp.name)
  self.feed=self.repo.manage({'action':'create','title':'Design news','rules':'Apple design news, exclude rumors'})['feed']
 def tearDown(self):self.temp.cleanup()
 def publish(self,**extra):
  return self.repo.publish({'feed_id':self.feed['id'],'revision':self.feed['revision'],'items':[{'title':'A useful update','body':'A user supplied update'}],**extra})
 def test_persistence_and_default_manual(self):
  data=FeedRepository(self.temp.name).snapshot();self.assertEqual(data['feeds'][0]['rules'],self.feed['rules']);self.assertEqual(data['feeds'][0]['interval_minutes'],0)
 def test_enabling_daily_window_does_not_hide_legacy_items(self):
  self.publish()
  self.repo.manage({'action':'update','id':self.feed['id'],'lookback_hours':24,'group_by_competitor':True})
  self.assertEqual(len(self.repo.snapshot()['items']),1)
 def test_update_preserves_other_fields(self):
  updated=self.repo.manage({'action':'update','id':self.feed['id'],'title':'New title'})['feed'];self.assertEqual(updated['rules'],self.feed['rules']);self.assertEqual(updated['revision'],2)
 def test_dedup_and_removed_item_stays_hidden(self):
  self.publish();self.publish();items=self.repo.snapshot()['items'];self.assertEqual(len(items),1)
  self.repo.item({'action':'hide','id':items[0]['id']});self.publish();self.assertEqual(self.repo.snapshot()['items'],[])
 def test_stale_revision_cannot_publish(self):
  self.repo.manage({'action':'update','id':self.feed['id'],'rules':'Only accessibility news'})
  with self.assertRaises(ValueError):self.publish()
  self.assertEqual(self.repo.snapshot()['items'],[])
 def test_batch_is_atomic(self):
  with self.assertRaises(ValueError):self.publish(items=[{'title':'Good','body':'Good'},{'title':'Bad','body':''}])
  self.assertEqual(self.repo.snapshot()['items'],[])
 def test_deleted_feed_cannot_reappear_via_refresh(self):
  self.publish();self.repo.manage({'action':'delete','id':self.feed['id']})
  with self.assertRaises(ValueError):self.publish()
  self.assertEqual(self.repo.snapshot(),{'feeds':[],'items':[]})
 def test_unsafe_url_and_interval_rejected(self):
  for url in ['javascript:alert(1)','file:///etc/passwd','https://user:pass@example.com','http://127.0.0.1']:
   with self.assertRaises(ValueError):self.repo.manage({'action':'update','id':self.feed['id'],'sources':[url]})
  with self.assertRaises(ValueError):self.repo.manage({'action':'update','id':self.feed['id'],'interval_minutes':1})
 def test_source_dedup_handles_changed_title(self):
  with patch.object(FeedRepository,'url',side_effect=lambda u:u):
   self.publish(items=[{'title':'Old','body':'old','url':'https://example.com/a'}]);self.publish(items=[{'title':'New','body':'new','url':'https://example.com/a'}])
  self.assertEqual(len(self.repo.snapshot()['items']),1);self.assertEqual(self.repo.snapshot()['items'][0]['title'],'New')
 def test_multiple_images_persist_and_replace(self):
  with patch.object(FeedRepository,'url',side_effect=lambda u:u):
   self.publish(items=[{'title':'Images','body':'A gallery','image_urls':['https://example.com/a.png','https://example.com/b.png','https://example.com/a.png']}])
   self.assertEqual(FeedRepository(self.temp.name).snapshot()['items'][0]['image_urls'],['https://example.com/a.png','https://example.com/b.png'])
   self.publish(items=[{'title':'Images','body':'Changed','image_urls':['https://example.com/c.png']}])
   self.assertEqual(self.repo.snapshot()['items'][0]['image_urls'],['https://example.com/c.png'])
 def test_legacy_single_image_remains_visible(self):
  with patch.object(FeedRepository,'url',side_effect=lambda u:u):
   self.publish(items=[{'title':'Old','body':'Legacy','image_url':'https://example.com/old.png'}])
  self.assertEqual(self.repo.snapshot()['items'][0]['image_urls'],['https://example.com/old.png'])
 def test_image_batch_rejection_is_atomic(self):
  with self.assertRaises(ValueError):
   self.publish(items=[{'title':'Good','body':'Good'},{'title':'Unsafe','body':'Bad','image_urls':['file:///etc/passwd']}])
  self.assertEqual(self.repo.snapshot()['items'],[])
  with self.assertRaises(ValueError):
   self.publish(items=[{'title':'Too many','body':'Bad','image_urls':['']*9}])
if __name__=='__main__':unittest.main()
