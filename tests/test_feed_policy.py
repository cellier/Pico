import sys,tempfile,time,unittest
from pathlib import Path
from datetime import datetime,timezone
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Backend'))
from feeds import FeedRepository
class DailyFeedTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.repo=FeedRepository(self.tmp.name)
  self.feed=self.repo.manage({'action':'create','title':'Competition','rules':'Daily competitors','interval_minutes':1440,'lookback_hours':24,'group_by_competitor':True})['feed']
  self.urls=patch.object(FeedRepository,'url',side_effect=lambda u:u);self.urls.start()
 def tearDown(self):self.urls.stop();self.tmp.cleanup()
 def item(self,name='Gamma',key='gamma-release',age=3600,url='https://example.com/news'):
  return {'competitor':name,'title':name+' announces a new feature','body':'A verified update','events':[{'key':key,'url':url,'published_at':datetime.fromtimestamp(time.time()-age,timezone.utc).isoformat()}]}
 def publish(self,items):return self.repo.publish({'feed_id':self.feed['id'],'revision':self.feed['revision'],'items':items})
 def test_daily_policy_persists(self):
  feed=FeedRepository(self.tmp.name).snapshot()['feeds'][0]
  self.assertEqual((feed['interval_minutes'],feed['lookback_hours'],feed['group_by_competitor']),(1440,24,1))
 def test_dates_reject_stale_future_unknown(self):
  for age in (86401,-10):
   with self.assertRaises(ValueError):self.publish([self.item(age=age)])
  item=self.item();item['events'][0]['published_at']='yesterday'
  with self.assertRaises(ValueError):self.publish([item])
  self.assertEqual(self.repo.snapshot()['items'],[])
 def test_one_item_per_competitor_and_alias(self):
  self.publish([self.item()]);self.publish([self.item('Gamma.app','gamma-next',url='https://example.com/next')])
  self.assertEqual(len(self.repo.snapshot()['items']),2)
  with self.assertRaises(ValueError):self.publish([self.item(),self.item('Gamma.app','other',url='https://example.com/other')])
 def test_repeat_event_and_tracking_url_do_not_republish(self):
  self.publish([self.item()])
  self.assertEqual(self.publish([self.item(url='https://example.com/syndicated')])['published'],0)
  self.assertEqual(self.publish([self.item(key='different-key',url='https://example.com/news?utm_source=x')])['published'],0)
 def test_empty_refresh_keeps_saved_history_visible(self):
  self.publish([self.item()])
  with patch('feeds.time.time',return_value=time.time()+90000):
   self.assertEqual(self.publish([])['published'],0)
   self.assertEqual(len(self.repo.snapshot()['items']),1)
   self.assertGreater(self.repo.snapshot()['feeds'][0]['last_refresh'],time.time()-1)
 def test_cross_competitor_duplicate_batch_rolls_back(self):
  with self.assertRaises(ValueError):self.publish([self.item(),self.item('Canva')])
  self.assertEqual(self.repo.snapshot()['items'],[])
 def test_removed_item_not_resurrected(self):
  self.publish([self.item()]);self.repo.item({'action':'hide','id':self.repo.snapshot()['items'][0]['id']})
  self.assertEqual(self.publish([self.item()])['published'],0)
  self.assertEqual(self.repo.snapshot()['items'],[])
  self.publish([self.item(key='new',url='https://example.com/new')]);self.assertEqual(len(self.repo.snapshot()['items']),1)
 def test_next_day_appends_and_preserves_read_history(self):
  self.publish([self.item()]);old=self.repo.snapshot()['items'][0]
  self.repo.item({'action':'read','id':old['id']})
  tomorrow=time.time()+86400
  with patch('time.time',return_value=tomorrow):
   self.publish([self.item(key='tomorrow',url='https://example.com/tomorrow')])
  items=FeedRepository(self.tmp.name).snapshot()['items']
  self.assertEqual(len(items),2)
  history=next(i for i in items if i['id']==old['id'])
  self.assertTrue(history['read'])
  for key in ('title','body','published'):self.assertEqual(history[key],old[key])
 def test_history_beyond_500_remains_visible(self):
  with self.repo.connect() as db:
   for index in range(501):
    db.execute('INSERT INTO items(id,feed_id,title,body,published) VALUES(?,?,?,?,?)',(str(index),self.feed['id'],'News','Details',index))
  self.assertEqual(len(self.repo.snapshot()['items']),501)
 def test_legacy_schema_migration_preserves_items(self):
  import sqlite3
  with tempfile.TemporaryDirectory() as directory:
   path=Path(directory)/'feeds.sqlite'
   # Reproduce the prior schema, including its obsolete uniqueness constraint.
   repo=FeedRepository(directory)
   feed=repo.manage({'action':'create','title':'Legacy','rules':'Keep history'})['feed']
   repo.publish({'feed_id':feed['id'],'items':[{'title':'Saved news','body':'Original'}]})
   with sqlite3.connect(path) as db:
    schema=db.execute("SELECT sql FROM sqlite_master WHERE name='items'").fetchone()[0]
    db.execute(schema.replace('CREATE TABLE items','CREATE TABLE legacy',1).rstrip(')')+',UNIQUE(feed_id,url,title))')
    db.execute('INSERT INTO legacy SELECT * FROM items');db.execute('DROP TABLE items');db.execute('ALTER TABLE legacy RENAME TO items')
   migrated=FeedRepository(directory)
   self.assertEqual(migrated.snapshot()['items'][0]['body'],'Original')
   with migrated.connect() as db:
    db.execute('INSERT INTO items(id,feed_id,title,body,published) VALUES(?,?,?,?,?)',('new',feed['id'],'Saved news','Next day',time.time()))
   self.assertEqual(len(migrated.snapshot()['items']),2)
 def test_rules_edit_preserves_policy(self):
  feed=self.repo.manage({'action':'update','id':self.feed['id'],'title':'New name'})['feed']
  self.assertEqual(feed['lookback_hours'],24);self.assertEqual(feed['group_by_competitor'],1)
if __name__=='__main__':unittest.main()
