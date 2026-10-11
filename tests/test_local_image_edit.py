import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from local_image_edit import working_size

class ImageSizingTests(unittest.TestCase):
    def test_retina_screenshot_is_bounded_and_not_stretched(self):
        content, canvas = working_size(3024, 1964)
        self.assertLessEqual(max(canvas), 1536)
        self.assertLessEqual(canvas[0] * canvas[1], 1024 * 1024 + 50000)
        self.assertAlmostEqual(content[0] / content[1], 3024 / 1964, places=2)
        self.assertEqual(canvas[0] % 16, 0)
        self.assertEqual(canvas[1] % 16, 0)
        self.assertLess(canvas[0] - content[0], 16)
        self.assertLess(canvas[1] - content[1], 16)

    def test_small_screenshot_is_not_upscaled(self):
        self.assertEqual(working_size(321, 213), ((321, 213), (336, 224)))

    def test_portrait_screenshot(self):
        content, canvas = working_size(800, 1464)
        self.assertLess(content[0], content[1])
        self.assertGreaterEqual(canvas[0], content[0])
        self.assertGreaterEqual(canvas[1], content[1])

    def test_tiny_image_rejected(self):
        with self.assertRaises(ValueError):
            working_size(0, 20)

if __name__ == '__main__':
    unittest.main()
