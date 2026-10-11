import json
import sys
import tempfile
import time
import unittest
from pathlib import Path
from datetime import datetime, timezone
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Backend'))
from feeds import FeedRepository
from feed_collection import FeedCollector, parse_feed, inspect_source, published_time
from feed_refresh import FeedRefresh

def response(text,url='https://example.com/feed',**extra):
    return {'text':text,'url':url,'not_modified':False,'etag':'v1','modified':'',**extra}

def rss(date=None,url='https://example.com/news/update'):
    date=date or datetime.fromtimestamp(time.time()-3600,timezone.utc).isoformat()
    return f'<rss><channel><item><title>Slides adds an API</title><link>{url}</link><pubDate>{date}</pubDate><description>Verified source text</description></item></channel></rss>'

class CollectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.repo=FeedRepository(self.tmp.name)
        self.validation=patch.object(FeedRepository,'url',side_effect=lambda u:u);self.validation.start()
        self.feed=self.repo.manage({'action':'create','title':'Slides','rules':'Slides product updates','sources':['https://example.com/feed'],
                                    'lookback_hours':24,'group_by_competitor':True,'interval_minutes':1440})['feed']
    def tearDown(self):self.validation.stop();self.tmp.cleanup()
    def state(self):return self.repo.snapshot()['feeds'][0]
    def refresh(self,fetch):
        refresh=FeedRefresh(self.repo,self.feed['id']);refresh.collector=FeedCollector(self.repo,fetch=fetch);refresh.collect();return refresh
    def publish(self,refresh,items=[]):
        return refresh.publish({'feed_id':self.feed['id'],'revision':self.feed['revision'],'items':items})
    def item(self,candidate):
        return {'competitor':'Google Slides','title':candidate['title'],'body':'An API update with a verified source.',
                'url':candidate['url'],'events':[{'key':'slides-api','url':candidate['url'],'published_at':candidate['published_at']}]}
    def test_rss_atom_and_json_feed_dates(self):
        self.assertEqual(parse_feed(rss(),'https://example.com')[0]['title'],'Slides adds an API')
        atom='<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>Slides</title><link href="/news/new"/><published>2026-10-06T01:00:00Z</published><summary>Update</summary></entry></feed>'
        self.assertEqual(parse_feed(atom,'https://example.com')[0]['url'],'https://example.com/news/new')
        data={'version':'https://jsonfeed.org/version/1.1','items':[{'url':'/news/json','title':'JSON','date_published':'2026-10-06T01:00:00Z'}]}
        self.assertGreater(parse_feed(json.dumps(data),'https://example.com')[0]['source_published'],0)
        self.assertEqual(published_time('2026-10-06'),0)
        self.assertEqual(published_time('unknown'),0)
    def test_html_feed_discovery_and_concrete_article_links(self):
        urls=[]
        def fetch(url,headers):
            urls.append(url)
            return response('<html><link rel="alternate" type="application/rss+xml" href="/rss"/></html>',url) if len(urls)==1 else response(rss(),url)
        result=inspect_source({'url':'https://example.com/blog'},fetch)
        self.assertEqual(urls,['https://example.com/blog','https://example.com/rss'])
        self.assertEqual(len(result['entries']),1)
        source='<html><a href="/blog/new-api">A new slides API update</a><a href="/pricing">Our pricing</a></html>'
        result=inspect_source({'url':'https://example.com'},lambda u,h:response(source,u))
        self.assertEqual(len(result['entries']),1);self.assertEqual(result['entries'][0]['source_published'],0)
    def test_malformed_feed_and_homepage_cannot_count_as_empty_success(self):
        for text in ('<rss><channel>', '<html><h1>Welcome to our website</h1></html>'):
            refresh=self.refresh(lambda u,h:response(text,u));self.publish(refresh)
            self.assertEqual(refresh.finish()['status'],'failed');self.assertEqual(self.state()['last_refresh'],0)
    def test_all_failed_empty_batch_keeps_checkpoint_and_retries(self):
        with self.repo.connect() as db:db.execute('UPDATE feeds SET last_refresh=?',(100,))
        def fail(u,h):raise TimeoutError('Source unavailable')
        refresh=self.refresh(fail);self.publish(refresh)
        result=refresh.finish();self.assertEqual(result['status'],'failed')
        self.assertEqual(self.state()['last_refresh'],100)
        self.assertGreater(self.state()['next_retry'],time.time()+890)
        self.assertEqual(self.state()['failure_count'],1)
    def test_successful_empty_feed_advances_checkpoint(self):
        refresh=self.refresh(lambda u,h:response('<rss><channel/></rss>',u));self.publish(refresh)
        self.assertEqual(refresh.finish()['status'],'ok');self.assertGreater(self.state()['last_refresh'],time.time()-2)
    def test_partial_sources_can_publish_without_advancing_checkpoint(self):
        self.feed=self.repo.manage({'action':'update','id':self.feed['id'],'sources':['https://example.com/feed','https://broken.com/feed']})['feed']
        def fetch(u,h):
            if 'broken' in u:raise TimeoutError('Unavailable')
            return response(rss(),u)
        refresh=self.refresh(fetch)
        candidate=refresh.collector.candidates(self.feed['id'])['candidates'][0]
        self.publish(refresh,[self.item(candidate)])
        result=refresh.finish();self.assertEqual(result['status'],'partial');self.assertEqual(result['published'],1)
        self.assertEqual(self.state()['last_refresh'],0);self.assertEqual(len(self.repo.snapshot()['items']),1)
    def test_search_failure_cannot_be_overridden_by_model_success(self):
        refresh=self.refresh(lambda u,h:response('<rss><channel/></rss>',u))
        refresh.record('search_web',{}, {'error':'All search providers unavailable'})
        self.publish(refresh);self.assertEqual(refresh.finish()['status'],'partial');self.assertEqual(self.state()['last_refresh'],0)
    def test_failed_article_cannot_be_dismissed_across_refreshes(self):
        refresh=self.refresh(lambda u,h:response(rss(),u))
        url=refresh.collector.candidates(self.feed['id'])['candidates'][0]['url']
        refresh.record('read_webpage',{'url':url},{'error':'Page too large'})
        candidate=refresh.collector.candidates(self.feed['id'])['candidates'][0]
        with self.assertRaises(ValueError):self.publish(refresh,[self.item(candidate)])
        self.assertEqual(refresh.collector.dismiss(self.feed['id'],[url])['left_pending'],[url])
        refresh.finish()
        refresh=FeedRefresh(self.repo,self.feed['id'])
        self.assertEqual(refresh.collector.dismiss(self.feed['id'],[url])['dismissed'],0)
        refresh.record('read_webpage',{'url':url},{'text':'Successfully verified original article'})
        self.assertEqual(refresh.collector.dismiss(self.feed['id'],[url])['dismissed'],1)
        refresh.finish()
    def test_pending_review_and_worker_exception_do_not_succeed(self):
        refresh=self.refresh(lambda u,h:response(rss(),u));self.publish(refresh)
        self.assertEqual(refresh.finish()['status'],'partial')
        refresh=self.refresh(lambda u,h:response(rss(),u));self.publish(refresh)
        self.assertEqual(refresh.finish(completed=False)['status'],'partial');self.assertEqual(self.state()['last_refresh'],0)
    def test_dated_backlog_publishes_with_real_date_and_delayed_label(self):
        old=datetime.fromtimestamp(time.time()-2*86400,timezone.utc).isoformat()
        refresh=self.refresh(lambda u,h:response(rss(old),u));candidate=refresh.collector.candidates(self.feed['id'])['candidates'][0]
        self.publish(refresh,[self.item(candidate)]);self.assertEqual(refresh.finish()['status'],'ok')
        item=self.repo.snapshot()['items'][0];self.assertEqual(item['delayed'],1)
        self.assertAlmostEqual(item['source_published'],datetime.fromisoformat(old).timestamp())
        self.assertEqual(refresh.collector.candidates(self.feed['id'])['candidates'],[])
    def test_fabricated_old_date_and_unknown_candidate_rejected(self):
        refresh=self.refresh(lambda u,h:response(rss(),u));candidate=refresh.collector.candidates(self.feed['id'])['candidates'][0]
        item=self.item(candidate);item['events'][0]['published_at']=datetime.fromtimestamp(time.time()-2*86400,timezone.utc).isoformat()
        with self.assertRaises(ValueError):self.publish(refresh,[item])
        item['events'][0]['url']='https://example.com/news/not-collected'
        with self.assertRaises(ValueError):self.publish(refresh,[item])
        refresh.finish(completed=False)
    def test_conditional_fetch_and_restarts_preserve_candidates_and_dispositions(self):
        requests=[]
        def fetch(u,h):requests.append(h);return response(rss(),u) if len(requests)==1 else {'not_modified':True}
        collector=FeedCollector(self.repo,fetch);collector.collect(self.feed['id'])
        collector=FeedCollector(FeedRepository(self.tmp.name),fetch);collector.collect(self.feed['id'],force=True)
        self.assertEqual(requests[1]['If-None-Match'],'v1')
        candidates=collector.candidates(self.feed['id'])['candidates'];self.assertEqual(len(candidates),1)
        collector.dismiss(self.feed['id'],[candidates[0]['url']]);collector.collect(self.feed['id'],force=True)
        self.assertEqual(collector.candidates(self.feed['id'])['candidates'],[])
    def test_source_failures_back_off_and_do_not_clear_previous_candidates(self):
        now=time.time();collector=FeedCollector(self.repo,lambda u,h:response(rss(),u))
        collector.collect(self.feed['id'],now=now)
        calls=[]
        def fail(u,h):calls.append(u);raise TimeoutError('Offline')
        collector.fetch=fail;collector.collect(self.feed['id'],force=True,now=now)
        collector.collect(self.feed['id'],now=now+60);self.assertEqual(len(calls),1)
        self.assertEqual(len(collector.candidates(self.feed['id'])['candidates']),1)
        collector.collect(self.feed['id'],now=now+901);self.assertEqual(len(calls),2)
    def test_duplicate_worker_lease_and_stale_recovery(self):
        first=FeedRefresh(self.repo,self.feed['id'])
        with self.assertRaises(ValueError):FeedRefresh(self.repo,self.feed['id'])
        with self.repo.connect() as db:db.execute('UPDATE feed_runs SET started=?',(time.time()-1300,))
        second=FeedRefresh(self.repo,self.feed['id'])
        first.finish(completed=False)
        self.assertEqual(self.state()['refresh_status'],'running') # Expired owner cannot overwrite its successor.
        second.finish(completed=False)
    def test_rule_changes_during_refresh_do_not_advance_checkpoint(self):
        refresh=self.refresh(lambda u,h:response('<rss><channel/></rss>',u));self.publish(refresh)
        self.repo.manage({'action':'update','id':self.feed['id'],'rules':'Only Slides API changes'})
        self.assertEqual(refresh.finish()['status'],'partial');self.assertEqual(self.state()['last_refresh'],0)
    def test_direct_publication_does_not_claim_discovery_success(self):
        self.repo.publish({'feed_id':self.feed['id'],'revision':self.feed['revision'],'items':[]})
        self.assertEqual(self.state()['last_refresh'],0)
    def test_candidate_batches_are_bounded_and_continue_after_triage(self):
        now=time.time()
        with self.repo.connect() as db:
            for i in range(35):
                db.execute('INSERT INTO feed_candidates(feed_id,url,source_url,title,excerpt,source_published,discovered) VALUES(?,?,?,?,?,?,?)',
                           (self.feed['id'],f'https://example.com/news/{i}','https://example.com/feed','News '+str(i),'x'*1600,now-i,now))
        collector=FeedCollector(self.repo)
        first=collector.candidates(self.feed['id']);self.assertEqual(first['pending_count'],35);self.assertEqual(len(first['candidates']),20)
        compact=collector.agent_view(first);self.assertTrue(all(len(c['excerpt'])==320 for c in compact['candidates']))
        self.assertEqual(len(collector.candidates(self.feed['id'],offset=20)['candidates']),15)
        collector.dismiss(self.feed['id'],[c['url'] for c in first['candidates']])
        self.assertEqual(collector.candidates(self.feed['id'])['pending_count'],15)
    def test_old_future_and_missing_publication_times(self):
        entries=''.join(rss(date).split('<channel>')[1].split('</channel>')[0] for date in (
            datetime.fromtimestamp(time.time()-8*86400,timezone.utc).isoformat(),
            datetime.fromtimestamp(time.time()+86400,timezone.utc).isoformat(),'unknown'))
        collector=FeedCollector(self.repo,lambda u,h:response('<rss><channel>'+entries+'</channel></rss>',u))
        candidates=collector.collect(self.feed['id'])['candidates'];self.assertEqual(len(candidates),1)
        self.assertIsNone(candidates[0]['published_at'])

if __name__=='__main__':unittest.main()
