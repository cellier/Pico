"""Factual news-card formatting, including a read-time adapter for older cards."""
import re

EDITORIAL_RULE = """Feed cards must use a specific factual NEWS HEADLINE describing what happened, never only a competitor/product name and never prefixes such as 标题: or Title:. Keep competitor identity in the competitor field, not as the headline. The body is ONE concise factual paragraph with inline Markdown links to the actual sources. Do not add subheadings, lists, or sections such as 发生了什么/为什么重要/意味着什么/What happened/Why it matters/Implications. Do not add strategic analysis, recommendations, speculation or unsupported claims. Preserve source qualifications (announced vs shipped, preview vs generally available, region and plan limits). Read and verify source pages before publishing; do not infer an announcement from a search snippet. Prefer primary sources. Include relevant images only when a working public image URL is verified on the source page; omit unavailable images rather than inventing them. These formatting rules supersede older saved feed templates requesting analysis sections; preserve their topics, sources and schedule."""

_PREFIX = re.compile(r'^\s*(?:#{1,6}\s*)?(?:\*\*)?(?:标题|title|headline)\s*[:：]\s*(?:\*\*)?', re.I)
_SECTION = re.compile(r'(?im)^\s*(?:#{1,6}\s*)?(?:\*\*)?(发生了什么|为什么重要|意味着什么|来源|what happened|why it matters|implications|sources?)\s*(?:[:：]\s*(?:\*\*)?|\*\*\s*[:：]?|$)\s*')
_ANALYSIS = {'为什么重要','意味着什么','why it matters','implications'}

def clean_title(title):
    return _PREFIX.sub('',title).strip().strip('*').strip()

def validate_editorial(title, body, competitor=''):
    if re.search(r'\n\s*\n', body) or _SECTION.search(body) or re.search(r'(?m)^\s*(?:#{1,6}\s|[-*]\s|\d+[.)]\s)', body):
        raise ValueError('Use one factual paragraph with inline source links, without subheadings, analysis sections or lists.')
    if competitor and re.sub(r'\W','',title).casefold()==re.sub(r'\W','',competitor).casefold():
        raise ValueError('The title must describe the news, not just name the competitor. Keep its name in competitor.')

def display_copy(title, body):
    """Remove only explicitly labeled legacy analysis; never synthesize new facts."""
    title = clean_title(title)
    matches = list(_SECTION.finditer(body))
    facts, sources = [], []
    for index, match in enumerate(matches):
        text = body[match.end():matches[index+1].start() if index+1<len(matches) else len(body)].strip()
        label = match.group(1).lower()
        if label in ('发生了什么','what happened'): facts.append(text)
        elif label in ('来源','source','sources'): sources.append(text)
    if facts:
        # Older cards used competitor-only headings; reuse the first factual clause verbatim.
        factual = re.sub(r'\*\*|__','', ' '.join(facts))
        headline = re.split(r'[。！？\n]|(?<=[.!?])\s', factual, maxsplit=1)[0].strip()
        if headline and len(headline)<=300 and 'http' not in headline: title = headline
        body = ' '.join(facts + sources)
    elif matches:
        kept = [body[:matches[0].start()].strip()]
        for index, match in enumerate(matches):
            if match.group(1).lower() not in _ANALYSIS:
                kept.append(body[match.end():matches[index+1].start() if index+1<len(matches) else len(body)].strip())
        body = ' '.join(kept)
    # Preserve existing Markdown destinations exactly, including underscores and parentheses.
    # Legacy plain-text source URLs become compact links only when no Markdown links exist.
    if not re.search(r'\]\(|<https?://', body):
        body = re.sub(r'https?://[^\s<>]+', lambda m: '[来源](<' + m.group(0).rstrip('。，；,;') + '>)' + m.group(0)[len(m.group(0).rstrip('。，；,;')):], body)
    return title, ' '.join(body.split())
