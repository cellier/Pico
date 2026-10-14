"""Local, bounded text extraction. Never execute Office macros or external relationships."""
import json
import re
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

LIMIT = 20000

def extract(path):
    path = Path(path)
    if path.stat().st_size > 50 * 1024 * 1024:
        raise ValueError('文件超过 50 MB')
    with zipfile.ZipFile(path) as archive:
        info = archive.infolist()
        if len(info) > 10000 or sum(i.file_size for i in info) > 20 * 1024 * 1024:
            raise ValueError('文档解压内容过大，请拆分材料')
        names = set(archive.namelist())
        if path.suffix.lower() == '.docx':
            selected = [('正文', 'word/document.xml')]
            tag = '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}p'
        elif path.suffix.lower() == '.pptx':
            # Presentation order comes from relationships, not slide file numbers.
            presentation = ET.fromstring(archive.read('ppt/presentation.xml'))
            rels = ET.fromstring(archive.read('ppt/_rels/presentation.xml.rels'))
            targets = {r.get('Id'): r.get('Target', '') for r in rels if r.get('TargetMode') != 'External'}
            selected = []
            for n, slide in enumerate(presentation.iter('{http://schemas.openxmlformats.org/presentationml/2006/main}sldId'), 1):
                target = targets.get(slide.get('{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id'), '')
                if not re.fullmatch(r'slides/slide\d+\.xml', target):
                    raise ValueError('不支持的幻灯片引用')
                selected.append((f'幻灯片 {n}', 'ppt/' + target))
            tag = '{http://schemas.openxmlformats.org/drawingml/2006/main}p'
        else:
            raise ValueError('仅支持 DOCX / PPTX')
        sections = []
        has_text = False
        for label, name in selected:
            if name not in names:
                raise ValueError('文档缺少必要内容')
            root = ET.fromstring(archive.read(name))
            paragraphs = [''.join(t.text or '' for t in p.iter() if t.tag.endswith('}t')) for p in root.iter(tag)]
            has_text = has_text or any(p.strip() for p in paragraphs)
            sections.append('[' + label + ']\n' + '\n'.join(p for p in paragraphs if p.strip()))
        text = '\n\n'.join(sections)
        if not has_text:
            raise ValueError('未找到可读文本；图片型材料需要先提供文字说明')
        if len(text) > LIMIT:
            raise ValueError('文字超过 20000 字符，请拆分或提供摘要；未截断内容')
        return text

if __name__ == '__main__':
    try:
        print(json.dumps({'text': extract(sys.argv[1])}, ensure_ascii=False))
    except Exception as error:
        print(json.dumps({'error': str(error)[:240]}, ensure_ascii=False))
        sys.exit(1)
