import sys, unittest, math
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Backend'))
from screenshot_annotation import validate, validate_design
class AnnotationTests(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(validate(dict(text='这里有重叠',x=.2,y=.7,style='arrow'))['text'],'这里有重叠')
    def test_invalid(self):
        for change in [dict(x=math.nan),dict(x=-.1),dict(y=1.1),dict(x=True),dict(text=''),dict(text='a'*161),dict(style='execute')]:
            with self.assertRaises(ValueError):validate(dict(dict(text='note',x=.2,y=.7,style='arrow'),**change))
    def test_low_contrast_is_repaired(self):
        design=validate_design(dict(surface='#FFFFFF',ink='#EEEEEE'))
        self.assertEqual(design['ink'],'#000000')
    def test_model_design_is_preserved(self):
        design=validate_design(dict(surface='#182231',ink='#FFFFFF',accent='#4876E8',connector='elbow',typeScale=1.15,weight='semibold',width=.42,radius=18,padding=22,eyebrow='排版问题'))
        self.assertEqual(design['connector'],'elbow')
        self.assertEqual(design['padding'],22)
        self.assertEqual(design['accent'],'#4876E8')
    def test_malformed_design_is_rejected(self):
        for change in [dict(surface='red'),dict(accent='#fff'),dict(width=4),dict(typeScale=float('nan')),dict(connector='script'),dict(padding=True),dict(eyebrow='x'*13)]:
            with self.assertRaises(ValueError):validate_design(change)
    def test_unsupported(self):
        self.assertIn('error',validate({'error':'Unsupported edit'}))
if __name__=='__main__': unittest.main()
