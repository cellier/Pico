import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('material', Path(__file__).parents[1]/'Backend/meeting_material.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class Materials(unittest.TestCase):
    def fixture(self, suffix, files):
        d = tempfile.TemporaryDirectory(); self.addCleanup(d.cleanup)
        p = Path(d.name)/('sample'+suffix)
        with zipfile.ZipFile(p, 'w') as z:
            for n,v in files.items(): z.writestr(n,v)
        return p
    def test_docx(self):
        p=self.fixture('.docx',{'word/document.xml':'<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>项目目标：获取建议</w:t></w:r></w:p></w:document>'})
        self.assertIn('获取建议',m.extract(p))
    def test_presentation_order_and_empty_last_slide(self):
        slide=lambda text: '<a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:r><a:t>'+text+'</a:t></a:r></a:p>'
        p=self.fixture('.pptx',{'ppt/presentation.xml':'<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldId r:id="two"/><p:sldId r:id="one"/></p:presentation>','ppt/_rels/presentation.xml.rels':'<Relationships><Relationship Id="two" Target="slides/slide2.xml"/><Relationship Id="one" Target="slides/slide1.xml"/></Relationships>','ppt/slides/slide2.xml':slide('Second file first in deck'),'ppt/slides/slide1.xml':slide('')})
        value=m.extract(p);self.assertTrue(value.startswith('[幻灯片 1]\nSecond'));self.assertIn('[幻灯片 2]',value)
    def test_no_text_not_success(self):
        with self.assertRaises(ValueError): m.extract(self.fixture('.docx',{'word/document.xml':'<empty/>'}))
    def test_no_silent_truncation(self):
        p=self.fixture('.docx',{'word/document.xml':'<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:t>'+('x'*20001)+'</w:t></w:p></w:document>'})
        with self.assertRaisesRegex(ValueError,'20000'):m.extract(p)
    def test_archive_size_bound(self):
        p=self.fixture('.docx',{'too-big':'x'*(20*1024*1024+1)})
        with self.assertRaisesRegex(ValueError,'过大'):m.extract(p)
if __name__=='__main__':unittest.main()
