"""Persistent, task-managed feeds. SQLite transactions coordinate native UI and agents."""
import contextlib, hashlib, json, os, sqlite3, sys, time, uuid
from pathlib import Path
from urllib.parse import urlparse
from feed_policy import validate_item
from feed_editorial import clean_title, validate_editorial, display_copy

class FeedRepository:
    def __init__(self, data):
        self.path=Path(data)/'feeds.sqlite'
        self.path.parent.mkdir(parents=True,exist_ok=True)
        with self.connect() as db:
            db.executescript('''
            CREATE TABLE IF NOT EXISTS feeds(id TEXT PRIMARY KEY,title TEXT NOT NULL,rules TEXT NOT NULL,sources TEXT NOT NULL DEFAULT '[]',interval_minutes INTEGER NOT NULL DEFAULT 0,enabled INTEGER NOT NULL DEFAULT 1,updated REAL NOT NULL,last_refresh REAL NOT NULL DEFAULT 0,task_id TEXT NOT NULL DEFAULT '',revision INTEGER NOT NULL DEFAULT 1);
            CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY,feed_id TEXT NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,title TEXT NOT NULL,body TEXT NOT NULL,url TEXT NOT NULL DEFAULT '',image_url TEXT NOT NULL DEFAULT '',published REAL NOT NULL,read INTEGER NOT NULL DEFAULT 0,hidden INTEGER NOT NULL DEFAULT 0);
            ''')
            columns = {row['name'] for row in db.execute('PRAGMA table_info(items)')}
            if 'image_urls' not in columns:
                db.execute("ALTER TABLE items ADD COLUMN image_urls TEXT NOT NULL DEFAULT '[]'")
            feed_columns={row['name'] for row in db.execute('PRAGMA table_info(feeds)')}
            for name, definition in [('lookback_hours','INTEGER NOT NULL DEFAULT 0'),('group_by_competitor','INTEGER NOT NULL DEFAULT 0'),('last_attempt','REAL NOT NULL DEFAULT 0'),('refresh_status',"TEXT NOT NULL DEFAULT 'unchecked'"),('refresh_error',"TEXT NOT NULL DEFAULT ''"),('next_retry','REAL NOT NULL DEFAULT 0'),('failure_count','INTEGER NOT NULL DEFAULT 0')]:
                if name not in feed_columns:db.execute(f'ALTER TABLE feeds ADD COLUMN {name} {definition}')
            for name, definition in [('competitor','TEXT NOT NULL DEFAULT \'\''),('source_published','REAL NOT NULL DEFAULT 0')]:
                if name not in columns:db.execute(f'ALTER TABLE items ADD COLUMN {name} {definition}')
            if 'delayed' not in columns:db.execute('ALTER TABLE items ADD COLUMN delayed INTEGER NOT NULL DEFAULT 0')
            # Older versions keyed cards by competitor and enforced URL/title uniqueness.
            # Event batches now have their own IDs, so repeated titles must be allowed.
            schema=db.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name='items'").fetchone()[0]
            if 'UNIQUE(feed_id,url,title)' in schema:
                db.execute(('CREATE TABLE items_history '+schema[schema.index('('):]).replace(',UNIQUE(feed_id,url,title)', ''))
                columns=[r['name'] for r in db.execute('PRAGMA table_info(items)')]
                names=','.join(columns)
                db.execute(f'INSERT INTO items_history ({names}) SELECT {names} FROM items')
                db.execute('DROP TABLE items')
                db.execute('ALTER TABLE items_history RENAME TO items')
            db.execute('CREATE TABLE IF NOT EXISTS feed_events(feed_id TEXT NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,event_key TEXT NOT NULL,source_url TEXT NOT NULL,competitor TEXT NOT NULL,published REAL NOT NULL,PRIMARY KEY(feed_id,event_key),UNIQUE(feed_id,source_url))')
            from feed_collection import SCHEMA
            db.executescript(SCHEMA)
            if 'verification_error' not in {r['name'] for r in db.execute('PRAGMA table_info(feed_candidates)')}:
                db.execute("ALTER TABLE feed_candidates ADD COLUMN verification_error TEXT NOT NULL DEFAULT ''")
        self.path.chmod(0o600)
    @contextlib.contextmanager
    def connect(self):
        with sqlite3.connect(self.path,timeout=10) as db:
            db.row_factory=sqlite3.Row;db.execute('PRAGMA foreign_keys=ON');yield db
    @staticmethod
    def url(value):
        if not value:return ''
        p=urlparse(value)
        if p.scheme not in ('https','http') or not p.hostname or p.username or p.password:
            raise ValueError('Sources must be public HTTP(S) URLs.')
        # Reuse network-boundary validation, including DNS/private-address checks.
        from worker import validate_url
        return validate_url(value)
    def snapshot(self):
        with self.connect() as db:
            feeds=[dict(r) for r in db.execute('SELECT * FROM feeds ORDER BY updated DESC')]
            items=[dict(r) for r in db.execute('SELECT items.* FROM items JOIN feeds ON items.feed_id=feeds.id WHERE hidden=0 ORDER BY items.published DESC')]
            for feed in feeds:
                sources=json.loads(feed['sources'])
                feed['source_count']=len(sources)
                feed['checked_sources']=sum(1 for r in db.execute('SELECT url,status,last_success FROM feed_sources WHERE feed_id=?',(feed['id'],)) if r['url'] in sources and r['status']=='ok' and r['last_success']>=time.time()-7200)
        for f in feeds:f['sources']=json.loads(f['sources']);f['enabled']=bool(f['enabled']);f['group_by_competitor']=bool(f['group_by_competitor'])
        for i in items:
            i['title'],i['body']=display_copy(i['title'],i['body'])
            i['read']=bool(i['read']);i['hidden']=bool(i['hidden'])
            i['image_urls']=json.loads(i['image_urls']) or ([i['image_url']] if i['image_url'] else [])
        return {'feeds':feeds,'items':items}
    def manage(self,args,task_id=''):
        action=args['action']
        if action=='list':
            result=self.snapshot()
            with self.connect() as db:result['recent_events']=[dict(r) for r in db.execute('SELECT * FROM feed_events WHERE published>=? ORDER BY published DESC LIMIT 2000',(time.time()-7*86400,))]
            return result
        feed_id=args.get('id') or str(uuid.uuid4())
        with self.connect() as db:
            old=db.execute('SELECT * FROM feeds WHERE id=?',(feed_id,)).fetchone()
            if action=='delete':
                if not old:raise ValueError('Feed not found')
                db.execute('DELETE FROM feeds WHERE id=?',(feed_id,));return {'deleted':feed_id}
            if action not in ('create','update'):raise ValueError('Unknown feed action')
            if action=='update' and not old:raise ValueError('Feed not found; list feeds first')
            def field(k,default):return args.get(k,old[k] if old else default)
            title=str(field('title','')).strip();rules=str(field('rules','')).strip()
            if not title or not rules or len(title)>160 or len(rules)>12000:raise ValueError('A title and clear content rules are required')
            sources=args.get('sources',json.loads(old['sources']) if old else [])
            if not isinstance(sources,list) or len(sources)>30:raise ValueError('Use at most 30 source URLs')
            sources=[self.url(u) for u in sources]
            interval=int(field('interval_minutes',0))
            if interval!=0 and not 15<=interval<=10080:raise ValueError('Refresh must be manual (0), or 15–10080 minutes')
            lookback=int(field('lookback_hours',0)); grouped=bool(field('group_by_competitor',False))
            if lookback not in (0,24) or (grouped != (lookback==24)):raise ValueError('Competitor feeds require a 24 hour window')
            revision=old['revision']+1 if old else 1
            db.execute('''INSERT INTO feeds(id,title,rules,sources,interval_minutes,enabled,updated,task_id,revision,lookback_hours,group_by_competitor) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET title=excluded.title,rules=excluded.rules,sources=excluded.sources,interval_minutes=excluded.interval_minutes,enabled=excluded.enabled,updated=excluded.updated,revision=excluded.revision,lookback_hours=excluded.lookback_hours,group_by_competitor=excluded.group_by_competitor''',
                (feed_id,title,rules,json.dumps(sources),interval,int(field('enabled',True)),time.time(),task_id,revision,lookback,int(grouped)))
        return {'feed':next(f for f in self.snapshot()['feeds'] if f['id']==feed_id),'refresh_note':'Automatic refresh runs while Pico is open. An unspecified schedule is manual.'}
    def publish(self,args,run_id=None):
        feed_id=args['feed_id'];entries=args['items']
        if not isinstance(entries,list) or len(entries)>60:raise ValueError('Publish 0–60 items; an empty list completes a refresh with no new news')
        with self.connect() as db:
            policy=db.execute('SELECT * FROM feeds WHERE id=?',(feed_id,)).fetchone()
        if not policy:raise ValueError('Feed was removed; do not recreate it automatically')
        with self.connect() as db:
            run=db.execute('SELECT * FROM feed_runs WHERE id=? AND feed_id=? AND status=?',(run_id,feed_id,'running')).fetchone() if run_id else None
            if run_id and not run:raise ValueError('Refresh is no longer active')
            collected={r['url']:r['source_published'] for r in db.execute('SELECT url,source_published FROM feed_candidates WHERE feed_id=? AND source_published>=?',(feed_id,time.time()-7*86400))}
        grouped=bool(policy['group_by_competitor']); batch_competitors=set(); metadata={}
        # Validate the entire batch before making any writes.
        prepared=[]
        for item in entries:
            title=clean_title(str(item.get('title','')));body=str(item.get('body','')).strip()
            validate_editorial(title,body,str(item.get('competitor','')))
            if not title or not body or len(title)>300 or len(body)>12000:raise ValueError('Each item needs a concise title and body')
            url=self.url(item.get('url',''));image=self.url(item.get('image_url',''))
            images=item.get('image_urls', [image] if image else [])
            if not isinstance(images,list) or len(images)>8:raise ValueError('Use at most 8 images per item')
            images=list(dict.fromkeys(self.url(value) for value in images if value))
            key=url or title.casefold()
            if grouped:
                key,competitor,events=validate_item(item,policy['lookback_hours'],self.url,collected=collected if run else {})
                if key in batch_competitors:raise ValueError('Publish one combined item per competitor')
                batch_competitors.add(key); metadata[key]=(competitor,events)
            card_key=key if not grouped else key+'\0'+json.dumps(sorted(e[0] for e in events))
            item_id=hashlib.sha256((feed_id+'\0'+card_key).encode()).hexdigest()[:32]
            prepared.append((key,(item_id,feed_id,title,body,url,image,time.time(),json.dumps(images))))
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            feed=db.execute('SELECT * FROM feeds WHERE id=?',(feed_id,)).fetchone()
            if not feed:raise ValueError('Feed was removed; do not recreate it automatically')
            if run_id and not db.execute("SELECT 1 FROM feed_runs WHERE id=? AND status='running'",(run_id,)).fetchone():
                raise ValueError('Refresh is no longer active')
            if args.get('revision') is not None and args['revision']!=feed['revision']:raise ValueError('Rules changed; re-read feed rules before publishing')
            if feed['revision']!=policy['revision']:raise ValueError('Rules changed; re-read feed rules')
            published_count=0
            for key,row in prepared:
                if grouped:
                    competitor,events=metadata[key]
                    if any(db.execute("SELECT 1 FROM feed_candidates WHERE feed_id=? AND url=? AND verification_error!=''",(feed_id,e[1])).fetchone() for e in events):
                        raise ValueError('An original article could not be verified; leave it pending and retry reading it before publishing')
                    existing=[db.execute('SELECT competitor FROM feed_events WHERE feed_id=? AND (event_key=? OR source_url=?)',(feed_id,e[0],e[1])).fetchone() for e in events]
                    if any(r and r['competitor']!=key for r in existing):raise ValueError('This news already belongs to another competitor item; merge it instead of duplicating')
                    if all(existing):continue
                    for event in events:
                        db.execute('INSERT OR IGNORE INTO feed_events(feed_id,event_key,source_url,competitor,published) VALUES(?,?,?,?,?)',(feed_id,event[0],event[1],key,event[2]))
                db.execute('''INSERT INTO items(id,feed_id,title,body,url,image_url,published,image_urls) VALUES(?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET title=excluded.title,body=excluded.body,url=excluded.url,image_url=excluded.image_url,image_urls=excluded.image_urls''',row)
                if grouped:
                    delayed=any(e[2]<time.time()-policy['lookback_hours']*3600 for e in events)
                    db.execute('UPDATE items SET competitor=?,source_published=?,published=?,delayed=? WHERE id=?',(competitor,max(e[2] for e in events),time.time(),int(delayed),row[0]))
                    for event in events:
                        db.execute("UPDATE feed_candidates SET disposition='published' WHERE feed_id=? AND url=?",(feed_id,event[1]))
                published_count+=1
            # Publishing proves only that cards were stored, not that discovery succeeded.
            # The worker-owned refresh session advances the checkpoint after checking coverage.
            if run_id:db.execute('UPDATE feed_runs SET published=published+?,did_publish=1 WHERE id=?',(published_count,run_id))
        return {'published':published_count,'feed_id':feed_id}
    def item(self,args):
        action=args['action']
        if action not in ('hide','read'):raise ValueError('Unknown item action')
        with self.connect() as db:
            db.execute('UPDATE items SET '+('hidden' if action=='hide' else 'read')+'=1 WHERE id=?',(args['id'],))
        return self.snapshot()

if __name__=='__main__':
    try:
        repo=FeedRepository(os.environ.get('TELOS_DATA_DIR',str(Path.home()/'Library/Application Support/Telos')))
        args=json.loads(sys.stdin.readline() or '{}')
        if args.get('command')=='manage':repo.manage(args)
        elif args.get('command')=='item':repo.item(args)
        print(json.dumps(repo.snapshot(),ensure_ascii=False))
    except Exception as e:print(json.dumps({'error':str(e)}));sys.exit(1)
