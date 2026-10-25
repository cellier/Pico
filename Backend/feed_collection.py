"""Durable, bounded source collection. This module never calls an AI model or publishes cards."""
import argparse
import concurrent.futures
import fcntl
import html
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from html.parser import HTMLParser
from pathlib import Path
from feed_policy import canonical_url

SCHEMA = '''
CREATE TABLE IF NOT EXISTS feed_sources(
 feed_id TEXT NOT NULL REFERENCES feeds(id) ON DELETE CASCADE, url TEXT NOT NULL,
 endpoint TEXT NOT NULL DEFAULT '', etag TEXT NOT NULL DEFAULT '', modified TEXT NOT NULL DEFAULT '',
 last_attempt REAL NOT NULL DEFAULT 0, last_success REAL NOT NULL DEFAULT 0,
 status TEXT NOT NULL DEFAULT 'unchecked', error TEXT NOT NULL DEFAULT '',
 failures INTEGER NOT NULL DEFAULT 0, next_check REAL NOT NULL DEFAULT 0,
 PRIMARY KEY(feed_id,url));
CREATE TABLE IF NOT EXISTS feed_candidates(
 feed_id TEXT NOT NULL REFERENCES feeds(id) ON DELETE CASCADE, url TEXT NOT NULL,
 source_url TEXT NOT NULL, title TEXT NOT NULL, excerpt TEXT NOT NULL DEFAULT '',
 source_published REAL NOT NULL DEFAULT 0, discovered REAL NOT NULL,
 disposition TEXT NOT NULL DEFAULT 'pending', verification_error TEXT NOT NULL DEFAULT '', PRIMARY KEY(feed_id,url));
CREATE TABLE IF NOT EXISTS feed_runs(
 id TEXT PRIMARY KEY, feed_id TEXT NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
 revision INTEGER NOT NULL, started REAL NOT NULL, finished REAL NOT NULL DEFAULT 0,
 status TEXT NOT NULL DEFAULT 'running', published INTEGER NOT NULL DEFAULT 0,
 did_publish INTEGER NOT NULL DEFAULT 0, error TEXT NOT NULL DEFAULT '');
'''

MAX_BYTES = 1_000_000
MAX_AGE = 7 * 86400

class SourceHTML(HTMLParser):
    def __init__(self):
        super().__init__(); self.feeds=[]; self.links=[]; self.parts=[]; self.label=[]; self.href=''; self.skip=0
    def handle_starttag(self, tag, attrs):
        values=dict(attrs)
        if tag=='link' and 'alternate' in values.get('rel','').lower() and any(t in values.get('type','') for t in ('rss','atom','feed+json')):
            self.feeds.append(values.get('href',''))
        if tag in ('script','style'):self.skip+=1
        if tag=='a':self.href=values.get('href','');self.label=[]
        if tag in ('p','div','br','li','h1','h2','h3'):self.parts.append('\n')
    def handle_endtag(self, tag):
        if tag in ('script','style'):self.skip=max(0,self.skip-1)
        if tag=='a' and self.href:
            self.links.append((self.href,''.join(self.label).strip()));self.href='';self.label=[]
    def handle_data(self,data):
        if not self.skip:
            self.parts.append(data)
            if self.href:self.label.append(data)

def clean_text(value):
    parser=SourceHTML();parser.feed(str(value or ''))
    return re.sub(r'\s+',' ',html.unescape(''.join(parser.parts))).strip()

def published_time(value):
    if not value:return 0
    try:
        date=datetime.fromisoformat(value.strip().replace('Z','+00:00'))
    except ValueError:
        try:date=parsedate_to_datetime(value)
        except (TypeError,ValueError,OverflowError):return 0
    # Date-only values are not silently assigned a time or timezone.
    return date.timestamp() if date.tzinfo else 0

def parse_feed(text, base):
    """Return None for HTML; malformed feeds fail rather than appearing empty."""
    stripped=text.lstrip('\ufeff \t\r\n')
    if stripped.startswith('{'):
        data=json.loads(stripped)
        if not str(data.get('version','')).startswith('https://jsonfeed.org/version/'):return None
        return [{'url':urllib.parse.urljoin(base,item.get('url','')), 'title':clean_text(item.get('title','')),
                 'excerpt':clean_text(item.get('content_text') or item.get('content_html') or item.get('summary',''))[:1600],
                 'source_published':published_time(item.get('date_published'))}
                for item in data.get('items',[])[:200] if item.get('url')]
    if not stripped.startswith('<'):return None
    if '<!ENTITY' in stripped.upper():
        raise ValueError('Feed document contains unsupported entities')
    if re.search(r'<!DOCTYPE\s+html\b',stripped[:600],re.I):return None
    try:root=ET.fromstring(stripped)
    except ET.ParseError:
        if re.search(r'<(?:rss|feed)\b',stripped[:600],re.I):raise ValueError('Malformed feed document')
        return None
    name=lambda tag:tag.rsplit('}',1)[-1]
    if name(root.tag) not in ('rss','feed','RDF'):return None
    result=[]
    for entry in (e for e in root.iter() if name(e.tag) in ('item','entry')):
        fields={name(e.tag):''.join(e.itertext()).strip() for e in entry}
        links=[e for e in entry if name(e.tag)=='link']
        link=next((e.get('href') for e in links if e.get('rel','alternate')=='alternate' and e.get('href')),fields.get('link',''))
        if not link:continue
        result.append({'url':urllib.parse.urljoin(base,link),'title':clean_text(fields.get('title','')),
                       'excerpt':clean_text(fields.get('description') or fields.get('summary') or fields.get('content') or fields.get('encoded',''))[:1600],
                       'source_updated':published_time(fields.get('updated')),
                       'source_published':published_time(fields.get('pubDate') or fields.get('published') or fields.get('date'))})
        if len(result)>=200:break
    return result

def fetch_source(url,headers=None):
    from worker import validate_url, PublicRedirect
    req=urllib.request.Request(validate_url(url),headers={'User-Agent':'Pico/0.6 Feed collector',**(headers or {})})
    try:
        with urllib.request.build_opener(PublicRedirect).open(req,timeout=12) as response:
            kind=response.headers.get('Content-Type','')
            body=response.read(MAX_BYTES+1)
            truncated=len(body)>MAX_BYTES
            if truncated and 'html' not in kind:raise ValueError('Source exceeds 1 MB')
            if not any(t in kind for t in ('text/','xml','json')):raise ValueError('Source is not text, XML or JSON')
            return {'url':response.url,'text':body[:MAX_BYTES].decode('utf-8',errors='replace'),'truncated':truncated,
                    'etag':response.headers.get('ETag',''),'modified':response.headers.get('Last-Modified',''),'not_modified':False}
    except urllib.error.HTTPError as error:
        if error.code==304:return {'not_modified':True}
        raise

def inspect_source(source,fetch=fetch_source):
    endpoint=source.get('endpoint') or source['url']
    headers={}
    if source.get('etag'):headers['If-None-Match']=source['etag']
    if source.get('modified'):headers['If-Modified-Since']=source['modified']
    response=fetch(endpoint,headers)
    if response['not_modified']:return {'endpoint':endpoint,'entries':[],**response}
    entries=parse_feed(response['text'],response['url'])
    if entries is None:
        page=SourceHTML();page.feed(response['text'])
        if page.feeds:
            endpoint=urllib.parse.urljoin(response['url'],page.feeds[0])
            response=fetch(endpoint,{})
            if response['not_modified']:raise ValueError('Uncached feed returned no content')
            entries=parse_feed(response['text'],response['url'])
            if entries is None:raise ValueError('Advertised feed is not RSS, Atom or JSON Feed')
        else:
            if response.get('truncated'):raise ValueError('HTML source exceeds 1 MB and has no discoverable feed')
            # Do not treat an HTML homepage as a dated news event. Store bounded
            # article links for verification by the agent, without invented dates.
            entries=[]
            for href,title in page.links:
                url=urllib.parse.urljoin(response['url'],href)
                path=urllib.parse.urlparse(url).path
                if len(title)>=15 and re.search(r'/(?:blog|news|insights|updates|release-notes)/[^/]+',path):
                    entries.append({'url':url,'title':title,'excerpt':'','source_published':0})
            entries=entries[:60]
            if not entries:raise ValueError('No structured feed or article links found; configure the publication feed URL')
    return {'endpoint':endpoint,'entries':entries,**{k:v for k,v in response.items() if k!='text'}}

class FeedCollector:
    def __init__(self,repo,fetch=fetch_source):self.repo=repo;self.fetch=fetch
    def collect(self,feed_id,force=False,now=None):
        now=time.time() if now is None else now
        with self.repo.connect() as db:
            feed=db.execute('SELECT * FROM feeds WHERE id=?',(feed_id,)).fetchone()
            if not feed:raise ValueError('Feed not found')
            urls=list(dict.fromkeys(json.loads(feed['sources'])))
            for url in urls:db.execute('INSERT OR IGNORE INTO feed_sources(feed_id,url) VALUES(?,?)',(feed_id,url))
            sources=[dict(r) for r in db.execute('SELECT * FROM feed_sources WHERE feed_id=?',(feed_id,)) if r['url'] in urls]
        due=[s for s in sources if force or s['next_check']<=now]
        def inspect(s):
            try:return s,inspect_source(s,self.fetch),None
            except Exception as error:return s,None,str(error)[:240]
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            for source,result,error in pool.map(inspect,due):
                with self.repo.connect() as db:
                    # A rule edit while fetching must not introduce stale candidates.
                    current=db.execute('SELECT revision FROM feeds WHERE id=?',(feed_id,)).fetchone()
                    if not current or current['revision']!=feed['revision']:continue
                    if error:
                        failures=source['failures']+1
                        db.execute("UPDATE feed_sources SET status='failed',error=?,failures=?,last_attempt=?,next_check=? WHERE feed_id=? AND url=?",
                                   (error,failures,now,now+min(6*3600,900*2**min(failures-1,5)),feed_id,source['url']))
                        continue
                    for entry in result['entries']:
                        url=entry['url'];date=entry['source_published']
                        # DNS/network validation is done only when fetching the article.
                        # Structural checks prevent credentials/private literal URLs here.
                        parts=urllib.parse.urlparse(url)
                        if parts.scheme not in ('http','https') or not parts.hostname or parts.username or parts.password:continue
                        if date and not now-MAX_AGE<=date<=now:continue
                        # Atom updated is useful for excluding old entries, but it
                        # must never masquerade as the original publication time.
                        updated=entry.get('source_updated',0)
                        if not date and updated and not now-MAX_AGE<=updated<=now:continue
                        if not entry['title']:continue
                        url=canonical_url(url)
                        disposition='published' if db.execute('SELECT 1 FROM feed_events WHERE feed_id=? AND source_url=?',(feed_id,url)).fetchone() else 'pending'
                        db.execute('''INSERT INTO feed_candidates(feed_id,url,source_url,title,excerpt,source_published,discovered,disposition)
                                      VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(feed_id,url) DO UPDATE SET title=excluded.title,
                                      excerpt=excluded.excerpt,source_published=excluded.source_published''',
                                   (feed_id,url,source['url'],entry['title'][:300],entry['excerpt'],date,now,disposition))
                    db.execute("UPDATE feed_sources SET endpoint=?,etag=?,modified=?,last_attempt=?,last_success=?,status='ok',error='',failures=0,next_check=? WHERE feed_id=? AND url=?",
                               (result['endpoint'],result.get('etag',source['etag']),result.get('modified',source['modified']),now,now,now+3600,feed_id,source['url']))
        return self.candidates(feed_id,now=now)

    def candidates(self,feed_id,now=None,offset=0):
        now=time.time() if now is None else now
        with self.repo.connect() as db:
            feed=db.execute('SELECT sources FROM feeds WHERE id=?',(feed_id,)).fetchone()
            if not feed:raise ValueError('Feed not found')
            urls=json.loads(feed['sources'])
            sources=[dict(r) for r in db.execute('SELECT * FROM feed_sources WHERE feed_id=?',(feed_id,)) if r['url'] in urls]
            candidates=[]
            pending_count=0
            if urls:
                placeholders=','.join('?' for _ in urls)
                clause="FROM feed_candidates WHERE feed_id=? AND disposition='pending' AND discovered>=? AND (source_published=0 OR source_published>=?) AND source_url IN ("+placeholders+")"
                params=(feed_id,now-MAX_AGE,now-MAX_AGE,*urls)
                pending_count=db.execute('SELECT count(*) '+clause,params).fetchone()[0]
                candidates=[dict(r) for r in db.execute('SELECT * '+clause+' ORDER BY source_published DESC, discovered DESC, url LIMIT 20 OFFSET ?',(*params,max(0,min(int(offset),10000))))]
        for candidate in candidates:
            candidate['published_at']=datetime.fromtimestamp(candidate['source_published'],timezone.utc).isoformat() if candidate['source_published'] else None
            candidate['delayed']=bool(candidate['source_published'] and candidate['source_published']<now-86400)
        return {'feed_id':feed_id,'candidates':candidates,'pending_count':pending_count,'offset':offset,'sources':sources,'untrusted':True,
                'current_time':datetime.fromtimestamp(now,timezone.utc).isoformat(),
                'daily_window_start':datetime.fromtimestamp(now-86400,timezone.utc).isoformat(),
                'catchup_window_start':datetime.fromtimestamp(now-MAX_AGE,timezone.utc).isoformat(),
                'note':'Verify article text before publishing. Undated links require original publication-date verification; never substitute discovery time. Dated backlog up to 7 days may be published as delayed discovery.'}

    @staticmethod
    def agent_view(result):
        view={k:v for k,v in result.items() if k not in ('candidates','sources')}
        view['candidates']=[{k:c[k] for k in ('url','source_url','title','published_at','delayed','verification_error')} | {'excerpt':c['excerpt'][:320]} for c in result['candidates']]
        view['sources']=[{k:s[k] for k in ('url','status','error')} for s in result['sources']]
        return view

    def dismiss(self,feed_id,urls):
        if not isinstance(urls,list) or len(urls)>60:raise ValueError('Dismiss at most 60 candidate URLs')
        dismissed=0;pending=[]
        with self.repo.connect() as db:
            for url in urls:
                url=canonical_url(url)
                row=db.execute("SELECT verification_error FROM feed_candidates WHERE feed_id=? AND url=? AND disposition='pending'",(feed_id,url)).fetchone()
                if row and row['verification_error']:pending.append(url);continue
                dismissed+=db.execute("UPDATE feed_candidates SET disposition='dismissed' WHERE feed_id=? AND url=? AND disposition='pending'",(feed_id,url)).rowcount
        return {'dismissed':dismissed,'left_pending':pending,'note':'Articles with a failed verification remain pending until a successful original-page read.'}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--data',default=os.environ.get('TELOS_DATA_DIR',str(Path.home()/'Library/Application Support/Telos')))
    parser.add_argument('--feed');parser.add_argument('--force',action='store_true');args=parser.parse_args()
    from feeds import FeedRepository
    repo=FeedRepository(args.data)
    # One collector per data directory, including launchd and manual invocations.
    with (Path(args.data)/'feed-collector.lock').open('a') as lock:
        os.chmod(lock.name,0o600)
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:return
        feeds=repo.snapshot()['feeds']
        for feed in feeds:
            if (args.feed and feed['id']==args.feed) or (not args.feed and feed['enabled'] and feed['interval_minutes']>0):
                result=FeedCollector(repo).collect(feed['id'],force=args.force)
                print(json.dumps({'feed':feed['title'],'pending':result['pending_count'],'sources':[{k:s[k] for k in ('url','status','error')} for s in result['sources']]},ensure_ascii=False))

if __name__=='__main__':main()
