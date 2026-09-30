"""Validation and identity rules for rolling competitor feeds."""
import re, time, unicodedata
from datetime import datetime
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode

def canonical_url(url):
    parts=urlsplit(url)
    query=[(k,v) for k,v in parse_qsl(parts.query,keep_blank_values=True) if not k.lower().startswith('utm_') and k.lower() not in {'fbclid','gclid','ref','source'}]
    return urlunsplit((parts.scheme.lower(),parts.netloc.lower(),parts.path.rstrip('/'),urlencode(sorted(query)),''))

def identity(name):
    value=re.sub(r'[^\w]+','',unicodedata.normalize('NFKC',name).casefold())
    aliases={'microsoftpowerpoint':'powerpoint','powerpointcopilot':'powerpoint','microsoftcopilotpowerpoint':'powerpoint','googleslidesgemini':'googleslides','presentationsai':'presentationsai','presentationai':'presentationsai','gammaapp':'gamma','gensparkslides':'genspark','figmaslides':'figma','wpsai':'wps'}
    return aliases.get(value,value)

def timestamp(value):
    if not isinstance(value,str):raise ValueError('Source published_at must be an ISO 8601 timestamp with a timezone')
    try: date=datetime.fromisoformat(value.replace('Z','+00:00'))
    except ValueError:raise ValueError('Source published_at must be an ISO 8601 timestamp with a timezone')
    if date.tzinfo is None:raise ValueError('Source published_at must include a timezone')
    return date.timestamp()

def validate_item(item,lookback_hours,validate_url,now=None):
    now=time.time() if now is None else now
    competitor=str(item.get('competitor','')).strip()
    if not competitor or len(competitor)>160:raise ValueError('Supply the canonical competitor name; combine its updates into one item')
    events=item.get('events',[])
    if not isinstance(events,list) or not 1<=len(events)<=20:raise ValueError('A competitor item needs 1–20 dated source events')
    result=[]
    for event in events:
        key=str(event.get('key','')).strip().casefold()
        if not key or len(key)>240:raise ValueError('Every event needs a stable key; reuse it for the same news across different sources')
        published=timestamp(event.get('published_at'))
        if not now-lookback_hours*3600<=published<=now:raise ValueError('Only verified news published within the current rolling window is allowed; exclude unknown or future dates')
        url=validate_url(event.get('url',''))
        if not url:raise ValueError('Every event needs a verified source URL')
        result.append((key,canonical_url(url),published))
    if len({x[0] for x in result})!=len(result) or len({x[1] for x in result})!=len(result):raise ValueError('Merge duplicate events and sources before publishing')
    canonical=identity(competitor)
    if not canonical:raise ValueError('Supply a valid competitor name')
    return canonical,competitor,result
