import unittest, tempfile, sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Backend'))
import worker
class WorkspaceTests(unittest.TestCase):
    def test_traversal_and_absolute_escape(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            self.assertEqual(worker.workspace_path(root,'report.md'),root.resolve()/'report.md')
            for name in ['../secret','/etc/passwd','.']:
                with self.assertRaises(ValueError): worker.workspace_path(root,name)
    def test_symlink_escape(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); (root/'outside').symlink_to('/etc')
            with self.assertRaises(ValueError): worker.workspace_path(root,'outside/passwd')
    def test_private_urls_are_rejected(self):
        for url in ['file:///etc/passwd','http://127.0.0.1','http://localhost','http://[::1]','http://user:password@example.com','https://example.com:9999']:
            with self.assertRaises(ValueError): worker.validate_url(url)
    def test_text_extraction_excludes_script(self):
        parser=worker.PlainText();parser.feed('<h1>Hello</h1><script>secret</script><p>World</p>')
        self.assertIn('World',''.join(parser.parts));self.assertNotIn('secret',''.join(parser.parts))
    def test_atomic_history(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'history.json';worker.atomic_json(path,[{'role':'user','content':'你好'}])
            import json,stat
            self.assertEqual(json.loads(path.read_text())[0]['content'],'你好')
            self.assertEqual(stat.S_IMODE(path.stat().st_mode),0o600)
if __name__=='__main__':unittest.main()
