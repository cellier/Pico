import sys, unittest, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from feed_editorial import clean_title, display_copy, validate_editorial
from feeds import FeedRepository

class EditorialTests(unittest.TestCase):
    def test_legacy_card_keeps_facts_qualifications_and_source(self):
        title, body = display_copy('Product', '**发生了什么：** 微软宣布预览功能，仅限美国。尚未全面推出。\n\n**为什么重要：** 战略判断\n\n**意味着什么：** 建议\n\n来源： 官方 https://example.com/a__b_(preview)')
        self.assertEqual(title, '微软宣布预览功能，仅限美国')
        self.assertIn('尚未全面推出', body)
        self.assertNotIn('战略判断', body)
        self.assertNotIn('建议', body)
        self.assertIn('[来源](<https://example.com/a__b_(preview)>)', body)
        self.assertNotIn('\n', body)
    def test_existing_markdown_links_preserved(self):
        original = 'New preview: [Official source](https://example.com/a__b_(preview)) for US users.'
        self.assertEqual(display_copy('News', original), ('News', original))
    def test_title_prefix(self):
        for title in ('标题：新版发布', '**标题：**新版发布', 'Title: 新版发布'):
            self.assertEqual(clean_title(title), '新版发布')
    def test_reject_old_template_and_lists(self):
        for body in ('**发生了什么**： 新功能', 'Why it matters: speculation', 'A\n\nB', '1. A', '# Heading', '- A'):
            with self.subTest(body=body), self.assertRaises(ValueError):
                validate_editorial('Product launches preview', body, 'Product')
    def test_competitor_identity_separate_from_headline(self):
        with self.assertRaises(ValueError): validate_editorial('Gamma', 'News', 'Gamma')
        validate_editorial('Gamma launches a preview', 'News', 'Gamma')
    def test_publish_rejects_whole_invalid_batch(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = FeedRepository(directory)
            feed = repo.manage({'action':'create','title':'News','rules':'Relevant updates'})['feed']
            with self.assertRaises(ValueError):
                repo.publish({'feed_id':feed['id'], 'items':[{'title':'News update','body':'Facts'}, {'title':'Another update','body':'为什么重要： speculation'}]})
            self.assertEqual(repo.snapshot()['items'], [])
    def test_snapshot_adapts_without_rewriting_saved_original(self):
        with tempfile.TemporaryDirectory() as directory:
            repo=FeedRepository(directory)
            feed=repo.manage({'action':'create','title':'News','rules':'Updates'})['feed']
            repo.publish({'feed_id':feed['id'],'items':[{'title':'标题：Product update','body':'Facts'}]})
            with repo.connect() as db:
                db.execute('UPDATE items SET body=?', ('发生了什么： Product announced a preview.\n为什么重要： Analysis',))
            self.assertEqual(repo.snapshot()['items'][0]['body'], 'Product announced a preview.')
            with repo.connect() as db:
                self.assertIn('为什么重要', db.execute('SELECT body FROM items').fetchone()['body'])

if __name__ == '__main__': unittest.main()
