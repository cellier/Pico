import hashlib
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from phone_skills import ALIASES, CANONICAL, SKILL_SHA256, phone_skill_args, register_phone_skill


class PhoneSkillTests(unittest.TestCase):
    def test_unchanged_reviewed_reference_is_registered_as_read_only_plugin_content(self):
        calls = []
        context = types.SimpleNamespace(register_skill=lambda *args, **kwargs: calls.append((args, kwargs)) or 'handle')
        with patch('importlib.metadata.version', return_value='0.3.2'):
            self.assertEqual(register_phone_skill(context), 'handle')
        args, kwargs = calls[0]
        self.assertEqual(args[0], 'phone-harness')
        self.assertEqual(hashlib.sha256(args[1].read_bytes()).hexdigest(), SKILL_SHA256)
        self.assertEqual(kwargs['frontmatter']['name'], 'phone-harness')
        self.assertIn('iPhone', kwargs['description'])

    def test_unknown_version_or_untrusted_reference_cannot_register(self):
        context = types.SimpleNamespace(register_skill=lambda *args, **kwargs: self.fail('must not register'))
        with patch('importlib.metadata.version', return_value='0.3.3'), self.assertRaises(ValueError):
            register_phone_skill(context)
        with tempfile.TemporaryDirectory() as directory:
            code = Path(directory) / 'phone_skills.py'
            path = code.parent / 'skills/phone-harness/SKILL.md'
            path.parent.mkdir(parents=True)
            path.write_text('unreviewed content')
            with patch('phone_skills.__file__', str(code)), \
                    patch('importlib.metadata.version', return_value='0.3.2'), self.assertRaises(ValueError):
                register_phone_skill(context)

    def test_official_legacy_alias_and_discoverable_name_route_to_the_canonical_skill(self):
        for name in ALIASES:
            args = {'name': name, 'file_path': 'references/example.md'}
            rewritten = phone_skill_args('skill_view', args, enabled=True)
            self.assertEqual(rewritten, {**args, 'name': CANONICAL})
            self.assertEqual(args['name'], name)
        unrelated = {'name': 'mac-tasks'}
        self.assertIs(phone_skill_args('skill_view', unrelated, enabled=True), unrelated)
        self.assertIs(phone_skill_args('skills_list', unrelated, enabled=True), unrelated)
        invalid = {'name': []}
        self.assertIs(phone_skill_args('skill_view', invalid, enabled=True), invalid)

    def test_disabled_and_feed_do_not_resolve_phone_aliases(self):
        for name in ALIASES:
            args = {'name': name}
            self.assertIs(phone_skill_args('skill_view', args, enabled=False), args)


if __name__ == '__main__':
    unittest.main()
