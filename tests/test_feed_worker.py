"""Exercise the real worker/tool protocol with a deterministic agent and source transport."""
import io
import json
import os
import sys
import tempfile
import time
import types
import unittest
import uuid
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Backend'))
import worker
from feeds import FeedRepository

class FeedWorkerTests(unittest.TestCase):
    def run_worker(self,source_failure=False):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup)
        root=Path(temp.name)
        (root/'config.json').write_text(json.dumps({'api_key':'fixture-only','base_url':'https://example.com/v1','model':'fixture'}))
        with patch.object(FeedRepository,'url',side_effect=lambda u:u):
            repo=FeedRepository(root)
            feed=repo.manage({'action':'create','title':'Slides','rules':'Only Google Slides product changes',
                             'sources':['https://example.com/rss'],'interval_minutes':1440,'lookback_hours':24,'group_by_competitor':True})['feed']
        tools={}
        class Registry:
            def register(self,**values):tools[values['name']]=values['handler']
        class Agent:
            def __init__(self,**kwargs):pass
            def run_conversation(self,prompt,**kwargs):
                assert 'run_python' not in tools and 'mac_action' not in tools
                assert json.loads(tools['get_current_time']({}))['current_time']
                call=lambda name,args:json.loads(tools[name](args))
                candidates=call('read_feed_candidates',{'feed_id':feed['id']})['candidates']
                if source_failure:
                    call('search_web',{'query':'slides'})
                    items=[]
                else:
                    c=candidates[0]
                    call('read_webpage',{'url':c['url']})
                    items=[{'competitor':'Google Slides','title':c['title'],'body':'Google Slides adds an API, according to the original source.',
                            'events':[{'key':'slides-api','url':c['url'],'published_at':c['published_at']}]}]
                value=call('publish_feed_items',{'feed_id':feed['id'],'revision':feed['revision'],'items':items})
                if 'error' in value:raise AssertionError(value)
                call('report_outcome',{'status':'ready','summary':'Reviewed the source'})
                return {'completed':True,'final_response':'已完成检查。','messages':[]}
        registry_module=types.ModuleType('tools.registry');registry_module.registry=Registry()
        agent_module=types.ModuleType('run_agent');agent_module.AIAgent=Agent
        original={'endpoint':'https://example.com/rss','etag':'','modified':'','entries':[{
            'url':'https://example.com/news/api','title':'Google Slides adds a comments API',
            'excerpt':'A factual announcement','source_published':time.time()-2*86400}]}
        output=io.StringIO()
        request={'task_id':str(uuid.uuid4()),'prompt':'Refresh the feed','new':False,'feed_id':feed['id']}
        with patch.dict(sys.modules,{'run_agent':agent_module,'tools.registry':registry_module}), \
             patch.dict('os.environ',{'TELOS_DATA_DIR':str(root)}), \
             patch('sys.stdin',io.StringIO(json.dumps(request))),patch.object(worker,'OUT',output), \
             patch('openai.OpenAI'),patch.object(FeedRepository,'url',side_effect=lambda u:u), \
             patch.object(worker,'read_url',return_value={'url':'https://example.com/news/api','text':'Original factual announcement'}), \
             patch('capabilities.Capabilities.search',return_value={'error':'Search unavailable'}), \
             patch('feed_collection.inspect_source',side_effect=TimeoutError('Offline') if source_failure else None,return_value=original):
            try:
                worker.main()
            finally:
                # worker.main enters its task workspace; restore before the
                # TemporaryDirectory cleanup removes that process-wide cwd.
                os.chdir(Path(__file__).resolve().parents[1])
        events=[json.loads(line) for line in output.getvalue().splitlines()]
        return repo,events
    def test_worker_publishes_dated_backlog_and_finishes_from_evidence(self):
        repo,events=self.run_worker()
        self.assertEqual(repo.snapshot()['feeds'][0]['refresh_status'],'ok')
        self.assertEqual(repo.snapshot()['items'][0]['delayed'],1)
        self.assertEqual(events[-1]['type'],'done')
    def test_worker_overrides_model_success_after_discovery_failure(self):
        repo,events=self.run_worker(source_failure=True)
        feed=repo.snapshot()['feeds'][0]
        self.assertEqual(feed['refresh_status'],'failed');self.assertEqual(feed['last_refresh'],0)
        self.assertIn('检查不完整',events[-1]['text'])
        self.assertEqual(repo.snapshot()['items'],[])

if __name__=='__main__':unittest.main()
