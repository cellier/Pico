import contextvars
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from mac_bridge import ApprovalGate
from phone_bridge import (PhoneBridge, PhoneBusy, PhoneCancelled, prepare_phone_home,
                          bundled_phone_plugin, filter_mirror_chrome_nodes,
                          install_mirror_chrome_compat, install_phone_runner, run_phone_runner,
                          import_task_screenshot, normalize_phone_images,
                          install_phone_ocr_compat, install_phone_unicode_launch_compat,
                          _spotlight_app_result)


class PhoneHomeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.data = Path(self.temp.name)
        self.home = self.data / 'tasks/task/hermes'
        self.source = self.data / 'hermes/plugins/phone-harness'
        self.source.mkdir(parents=True)
        (self.source / 'plugin.yaml').write_text('name: phone-harness\nversion: 0.1.0\n')
        (self.source / '__init__.py').write_text('def register(ctx): pass\n')
        (self.source / '.git').mkdir()
        (self.source / '.git/private').write_text('excluded')
        (self.source.parent / '.install-metadata.json').write_text(json.dumps({
            'phone-harness': {'revision': 'reviewed'}, 'unrelated': {'revision': 'other'}}))
        (self.data / 'hermes/config.yaml').write_text(
            'plugins:\n  enabled: [phone-harness, unrelated]\n'
            '  entries:\n    phone-harness:\n      settings:\n        classifier_auto_run: false\n'
            'api_key: shared-secret-must-stay-out\n')
        self.env = patch.dict(os.environ, {}, clear=False)
        self.env.start()
        self.addCleanup(self.env.stop)

    def config(self):
        import yaml
        return yaml.safe_load((self.home / 'config.yaml').read_text())

    def test_only_enabled_phone_is_materialized_before_discovery(self):
        self.assertTrue(prepare_phone_home(self.data, self.home))
        target = self.home / 'plugins/phone-harness'
        self.assertEqual((target / '__init__.py').read_bytes(), (self.source / '__init__.py').read_bytes())
        self.assertFalse((target / '.git').exists())
        self.assertEqual(self.config()['plugins']['enabled'], ['phone-harness'])
        self.assertEqual(set(json.loads((target.parent / '.install-metadata.json').read_text())), {'phone-harness'})
        self.assertNotIn('api_key', self.config())
        self.assertEqual(self.config()['approvals']['mode'], 'manual')
        self.assertEqual(os.environ['PHONE_HARNESS_PLATFORM'], 'ios')
        self.assertEqual(os.environ['PHONE_HARNESS_TELEMETRY'], '0')
        self.assertEqual(os.environ['PHONE_HARNESS_CLASSIFIER_AUTO_RUN'], '0')
        self.assertTrue(Path(os.environ['PH_AGENT_WORKSPACE']).is_relative_to(self.home))

    def test_feed_has_no_phone_even_after_previous_normal_turn(self):
        prepare_phone_home(self.data, self.home)
        self.assertFalse(prepare_phone_home(self.data, self.home, feed=True))
        self.assertFalse((self.home / 'plugins/phone-harness').exists())
        self.assertEqual(self.config()['plugins']['enabled'], [])
        self.assertEqual(self.config()['plugins']['disabled'], ['phone-harness'])

    def test_disabled_and_missing_plugin_do_not_enable_tools(self):
        for config in ('plugins: {enabled: []}',
                       'plugins: {enabled: [phone-harness], disabled: [phone-harness]}'):
            (self.data / 'hermes/config.yaml').write_text(config)
            self.assertFalse(prepare_phone_home(self.data, self.home))
        (self.data / 'hermes/config.yaml').write_text('plugins: {enabled: [phone-harness]}')
        (self.source / '__init__.py').unlink()
        self.assertFalse(prepare_phone_home(self.data, self.home))

    def test_existing_task_settings_and_workspace_survive(self):
        self.home.mkdir(parents=True)
        (self.home / 'config.yaml').write_text('tools: {tool_search: {enabled: off}}\nsessions: {auto_prune: false}')
        notes = self.home / 'plugin-data/phone-harness/agent-workspace/agent_helpers.py'
        notes.parent.mkdir(parents=True)
        notes.write_text('# custom learned helper')
        prepare_phone_home(self.data, self.home)
        prepare_phone_home(self.data, self.home)
        self.assertFalse(self.config()['sessions']['auto_prune'])
        self.assertIn('tool_search', self.config()['tools'])
        self.assertEqual(notes.read_text(), '# custom learned helper')

    def test_external_plugin_symlink_is_rejected(self):
        secret = self.data / 'secret'
        secret.write_text('must not copy')
        (self.source / 'outside').symlink_to(secret)
        with self.assertRaises(ValueError):
            prepare_phone_home(self.data, self.home)
        self.assertFalse((self.home / 'plugins/phone-harness/outside').exists())

    def test_fresh_packaged_install_uses_trusted_bundle_without_resetting_shared_choices(self):
        bundle = self.data / 'bundled-phone'
        self.source.rename(bundle)
        (self.source.parent / '.install-metadata.json').unlink()
        shared_config = self.data / 'hermes/config.yaml'
        shared_config.unlink()
        with patch('phone_bridge.bundled_phone_plugin', return_value=bundle):
            self.assertTrue(prepare_phone_home(self.data, self.home))
        self.assertTrue((self.home / 'plugins/phone-harness/__init__.py').is_file())
        self.assertFalse(shared_config.exists())

    def test_explicit_disabled_selection_or_uninstall_never_uses_bundle(self):
        bundle = self.data / 'bundled-phone'
        self.source.rename(bundle)
        metadata = self.source.parent / '.install-metadata.json'
        metadata.unlink()
        shared_config = self.data / 'hermes/config.yaml'
        choices = ['plugins: {enabled: []}',
                   'plugins: {disabled: [phone-harness]}',
                   'plugins: {entries: {phone-harness: {enabled: false}}}']
        with patch('phone_bridge.bundled_phone_plugin', return_value=bundle) as fallback:
            for config in choices:
                shared_config.write_text(config)
                self.assertFalse(prepare_phone_home(self.data, self.home))
                self.assertEqual(shared_config.read_text(), config)
            shared_config.unlink()
            metadata.write_text('{"phone-harness": {"revision": "removed-by-user"}}')
            self.assertFalse(prepare_phone_home(self.data, self.home))
            metadata.unlink()
            self.assertFalse(prepare_phone_home(self.data, self.home, feed=True))
            fallback.assert_not_called()

    def test_bundle_location_and_integrity_are_checked(self):
        code = self.data / 'App/Contents/Resources/Backend/phone_bridge.py'
        bundled = code.parent.parent / 'Runtime/plugins/phone-harness'
        bundled.mkdir(parents=True)
        hashes = {}
        for name in ('plugin.yaml', '__init__.py', 'README.md'):
            content = ('reviewed fixture ' + name).encode()
            (bundled / name).write_bytes(content)
            hashes[name] = hashlib.sha256(content).hexdigest()
        with patch('phone_bridge.__file__', str(code)), patch('phone_bridge._BUNDLED_FILES', hashes):
            self.assertEqual(bundled_phone_plugin(), bundled.resolve())
            (bundled / '__init__.py').write_text('modified source')
            with self.assertRaises(ValueError):
                bundled_phone_plugin()


class MirrorChromeTests(unittest.TestCase):
    @staticmethod
    def node(role='AXButton', text='', **attributes):
        return role, text, attributes

    def test_connected_window_toolbar_is_not_an_interstitial(self):
        nodes = [self.node(AXSubrole=role) for role in
                 ('AXCloseButton', 'AXMinimizeButton', 'AXZoomButton')]
        nodes += [self.node(text='Home Screen', AXIdentifier='app.grid.3x3'),
                  self.node(text='App Switcher', AXIdentifier='iphone.app.switcher')]
        self.assertEqual(filter_mirror_chrome_nodes(nodes, lambda node, key: node.get(key)), [])

    def test_known_and_unknown_interstitials_still_block(self):
        for text in ('Connect', 'iPhone in Use', 'Try Again', '连接', '', 'Future Apple prompt'):
            body = self.node(text=text, AXIdentifier='unknown.control')
            label = self.node(role='AXStaticText', text='User must unlock the phone')
            chrome = self.node(text='Home Screen', AXIdentifier='app.grid.3x3')
            self.assertEqual(filter_mirror_chrome_nodes([chrome, body, label], lambda n, k: n.get(k)),
                             [body, label])

    def test_matching_label_or_partial_identifier_does_not_make_a_node_safe(self):
        nodes = [self.node(text='Home Screen'), self.node(text='App Switcher'),
                 self.node(AXIdentifier='app.grid.3x3.new'),
                 self.node(AXIdentifier='other.iphone.app.switcher'),
                 self.node(role='AXStaticText', AXIdentifier='app.grid.3x3')]
        self.assertEqual(filter_mirror_chrome_nodes(nodes, lambda n, k: n.get(k)), nodes)

    def test_failed_ax_identity_read_keeps_blocker(self):
        node = self.node(text='Unknown')
        def failed(*args):
            raise RuntimeError('AX identity unavailable')
        self.assertEqual(filter_mirror_chrome_nodes([node], failed), [node])

    def test_memory_patch_is_version_scoped_and_idempotent(self):
        toolbar = self.node(AXIdentifier='app.grid.3x3')
        blocker = self.node(text='Connect', AXIdentifier='connection.button')
        original = lambda *a, **k: [toolbar, blocker]
        api = types.SimpleNamespace(AXUIElementCopyAttributeValue=lambda node, key, unused: (0, node.get(key)))
        mirror = types.SimpleNamespace(_window_ax_nodes=original, _AS=api)
        self.assertFalse(install_mirror_chrome_compat(mirror, '0.3.3'))
        self.assertIs(mirror._window_ax_nodes, original)
        self.assertTrue(install_mirror_chrome_compat(mirror, '0.3.2'))
        patched = mirror._window_ax_nodes
        self.assertEqual(patched('app', win={}), [blocker])
        self.assertTrue(install_mirror_chrome_compat(mirror, '0.3.2'))
        self.assertIs(mirror._window_ax_nodes, patched)

    def test_child_entry_changes_without_changing_handler_hook_or_script(self):
        handler = object()
        hook = object()
        plugin = types.SimpleNamespace(_command=lambda: [sys.executable, '-m', 'phone_harness.run'],
                                       phone_exec=handler, _on_pre_tool_call=hook)
        self.assertTrue(install_phone_runner(plugin))
        command = plugin._command()
        self.assertEqual(command[0], sys.executable)
        self.assertEqual(command[2:], ['--phone-runner'])
        self.assertEqual(Path(command[1]).name, 'phone_bridge.py')
        self.assertIs(plugin.phone_exec, handler)
        self.assertIs(plugin._on_pre_tool_call, hook)
        self.assertTrue(install_phone_runner(plugin))
        missing = types.SimpleNamespace(_command=lambda: None)
        self.assertTrue(install_phone_runner(missing))
        self.assertIsNone(missing._command())
        unexpected = types.SimpleNamespace(_command=lambda: ['other-python', '-m', 'other'])
        self.assertTrue(install_phone_runner(unexpected))
        with self.assertRaises(ValueError):
            unexpected._command()

    def test_bootstrap_patches_child_before_official_runner_and_preserves_stdin(self):
        fake_phone = types.ModuleType('phone_harness')
        fake_phone.mirror = object()
        fake_phone.ocr = object()
        fake_phone.ios = object()
        original_stdin = sys.stdin
        with patch.dict(sys.modules, {'phone_harness': fake_phone}), \
                patch('importlib.metadata.version', return_value='0.3.2'), \
                patch('phone_bridge.install_mirror_chrome_compat') as compatibility, \
                patch('phone_bridge.install_phone_ocr_compat') as bilingual, \
                patch('phone_bridge.install_phone_unicode_launch_compat') as unicode_launch, \
                patch('runpy.run_module') as run, patch.object(sys, 'argv', ['bridge', '--phone-runner']):
            def check_run(*args, **kwargs):
                compatibility.assert_called_once_with(fake_phone.mirror, '0.3.2')
                bilingual.assert_called_once_with(fake_phone.ocr, '0.3.2')
                unicode_launch.assert_called_once_with(fake_phone.ios, '0.3.2')
                self.assertIs(sys.stdin, original_stdin)
                self.assertEqual(sys.argv, ['phone_harness.run'])
            run.side_effect = check_run
            run_phone_runner()
            run.assert_called_once_with('phone_harness.run', run_name='__main__')


class PhoneLanguageCompatTests(unittest.TestCase):
    def test_ocr_injects_both_languages_only_into_its_own_requests(self):
        requests = []
        class Request:
            @classmethod
            def alloc(cls):
                return cls()
            def init(self):
                requests.append(self)
                return self
            def setRecognitionLanguages_(self, languages):
                self.languages = languages
        vision = types.SimpleNamespace(VNRecognizeTextRequest=Request,
                                       VNRequestTextRecognitionLevelAccurate=123,
                                       VNImageRequestHandler=object())
        recognize = object()
        ocr = types.SimpleNamespace(Vision=vision, recognize=recognize)
        self.assertFalse(install_phone_ocr_compat(ocr, '0.3.3'))
        self.assertIs(ocr.Vision, vision)
        self.assertTrue(install_phone_ocr_compat(ocr, '0.3.2'))
        proxy = ocr.Vision
        for _ in range(2):
            request = proxy.VNRecognizeTextRequest.alloc().init()
            self.assertEqual(request.languages, ['zh-Hans', 'en-US'])
        self.assertIs(ocr.recognize, recognize)
        self.assertIs(proxy.VNImageRequestHandler, vision.VNImageRequestHandler)
        self.assertEqual(proxy.VNRequestTextRecognitionLevelAccurate, 123)
        unpatched = vision.VNRecognizeTextRequest.alloc().init()
        self.assertFalse(hasattr(unpatched, 'languages'))
        self.assertTrue(install_phone_ocr_compat(ocr, '0.3.2'))
        self.assertIs(ocr.Vision, proxy)
        self.assertEqual(len(requests), 3)

    @staticmethod
    def launch_fixture(frames, window=None):
        events = []
        class Device:
            def _apps_launch(self, name):
                events.append(('original', name))
                return 'original-result'
        ios = types.SimpleNamespace(IPhone=Device, _sleep=lambda delay: events.append(('sleep', delay)))
        device = Device()
        device._raise_if_not_live = lambda: events.append(('live',))
        index = [0]
        def screen():
            current = min(index[0], len(frames) - 1)
            events.append(('screen', index[0]))
            index[0] += 1
            return frames[current]
        device._screen_text = screen
        device.mirror = types.SimpleNamespace(
            press=lambda key: events.append(('press', key)),
            type_text=lambda text, **kwargs: events.append(('type_text', text, kwargs)),
            find_window=lambda: window or {'x': 100, 'y': 60, 'w': 326, 'h': 720},
            tap=lambda x, y: events.append(('tap', x, y)))
        return ios, device, events

    @staticmethod
    def spotlight(query, app='WeChat', *, duplicate=False):
        def text(label, y, x=180):
            return {'text': label, 'x': x, 'y': y, 'w': 40, 'h': 14, 'confidence': 1.0}
        rows = [text('Top Hit', 160), text('微众银行', 220), text('Apps', 360),
                text(app, 415), text(query, 725)]
        if duplicate:
            rows.append(text(app, 415, x=260))
        return rows

    def test_other_ascii_launch_keeps_original_behavior_and_version_scope(self):
        ios, device, events = self.launch_fixture([[]])
        original = ios.IPhone._apps_launch
        self.assertFalse(install_phone_unicode_launch_compat(ios, '0.3.3'))
        self.assertIs(ios.IPhone._apps_launch, original)
        self.assertTrue(install_phone_unicode_launch_compat(ios, '0.3.2'))
        patched = ios.IPhone._apps_launch
        self.assertEqual(device._apps_launch('Notes'), 'original-result')
        self.assertEqual(events, [('original', 'Notes')])
        self.assertTrue(install_phone_unicode_launch_compat(ios, '0.3.2'))
        self.assertIs(ios.IPhone._apps_launch, patched)

    def test_wrong_top_hit_is_ignored_and_old_query_is_cleared_before_typing(self):
        for name in ('微信', 'WeChat', 'wechat'):
            with self.subTest(name=name):
                ios, device, events = self.launch_fixture([
                    self.spotlight('旧查询'), self.spotlight('WeChat')])
                install_phone_unicode_launch_compat(ios, '0.3.2')
                self.assertEqual(device._apps_launch(name), name)
                self.assertEqual(events[:7], [('press', 'cmd+3'), ('screen', 0), ('live',),
                                              ('press', 'cmd+a'), ('press', 'backspace'),
                                              ('type_text', 'WeChat', {'keystrokes': True}), ('screen', 1)])
                self.assertEqual([event for event in events if event[0] == 'tap'], [('tap', 180, 415)])
                self.assertNotIn(('press', 'return'), events)

    def test_pending_unicode_paste_must_appear_in_query_before_any_result_is_tapped(self):
        ios, device, events = self.launch_fixture([
            self.spotlight('旧查询', app='日历'),
            self.spotlight('旧查询', app='日历'),
            self.spotlight('日历', app='日历')])
        install_phone_unicode_launch_compat(ios, '0.3.2')
        self.assertEqual(device._apps_launch('日历'), '日历')
        self.assertIn(('type_text', '日历', {'keystrokes': False}), events)
        self.assertLess(events.index(('screen', 2)), events.index(('tap', 180, 415)))
        self.assertNotIn(('press', 'return'), events)

    def test_multiple_app_labels_are_rejected_instead_of_selecting_an_arbitrary_hit(self):
        ios, device, events = self.launch_fixture([
            self.spotlight('旧查询'), self.spotlight('WeChat', duplicate=True)])
        install_phone_unicode_launch_compat(ios, '0.3.2')
        with self.assertRaisesRegex(ValueError, 'multiple exact app matches'):
            device._apps_launch('微信')
        self.assertFalse(any(event[0] == 'tap' for event in events))
        self.assertNotIn(('press', 'return'), events)

    def test_wechat_can_use_one_exact_top_hit_when_apps_section_is_absent(self):
        result = self.spotlight('WeChat')
        result = [row for row in result if row['text'] != 'Apps' and row['y'] != 415]
        result[1] = {**result[1], 'text': 'WeChat'}
        ios, device, events = self.launch_fixture([self.spotlight('旧查询'), result])
        install_phone_unicode_launch_compat(ios, '0.3.2')
        device._apps_launch('微信')
        self.assertEqual([event for event in events if event[0] == 'tap'], [('tap', 180, 220)])
        self.assertNotIn(('press', 'return'), events)

    def test_duplicate_wechat_label_in_top_hit_and_apps_prefers_apps(self):
        result = self.spotlight('WeChat')
        result[1] = {**result[1], 'text': 'WeChat'}
        ios, device, events = self.launch_fixture([self.spotlight('旧查询'), result])
        install_phone_unicode_launch_compat(ios, '0.3.2')
        device._apps_launch('WeChat')
        self.assertEqual([event for event in events if event[0] == 'tap'], [('tap', 180, 415)])

    def test_suggestions_files_and_websites_do_not_become_top_hit_apps(self):
        def row(text, y):
            return {'text': text, 'x': 180, 'y': y, 'w': 40, 'h': 14, 'confidence': 1.0}
        result = [row('Top Hit', 160), row('WeChat', 220), row('Suggestions', 300),
                  row('WeChat', 350), row('Files', 400), row('wechat', 450),
                  row('Websites', 500), row('WeChat', 550), row('WeChat', 725)]
        ios, device, events = self.launch_fixture([self.spotlight('旧查询'), result])
        install_phone_unicode_launch_compat(ios, '0.3.2')
        device._apps_launch('微信')
        self.assertEqual([event for event in events if event[0] == 'tap'], [('tap', 180, 220)])

    @staticmethod
    def observed_spotlight():
        # Real failed regression's UI-only OCR geometry, without user images,
        # web results, file contents, or any private conversation text.
        window = {'x': 1174., 'y': 196., 'w': 326., 'h': 720.}
        labels = [('Top Hit', .5, 1215., 299., 42., 14.),
                  ('WeChat', .5, 1231., 381., 38., 10.),
                  ('Suggestions', 1., 1229., 423., 70.3, 15.4),
                  ('WeChat', .5, 1249., 458., 54.1, 16.5),
                  ('Files', 1., 1208., 498., 28., 12.),
                  ('wechat', .5, 1278., 534., 48., 12.),
                  ('Websites', 1., 1221., 679., 54., 10.),
                  ('Wechat', 1., 1278., 723., 52., 14.2),
                  ('WeChat', .5, 1265., 862., 54.1, 12.4)]
        rows = [dict(zip(('text', 'confidence', 'x', 'y', 'w', 'h'), label)) for label in labels]
        return window, rows

    def test_observed_half_confidence_labels_select_the_top_hit_app_only(self):
        window, rows = self.observed_spotlight()
        hit = _spotlight_app_result(rows, window, 'WeChat', {'微信', 'wechat'}, allow_wechat_top_hit=True)
        self.assertEqual((hit['x'], hit['y'], hit['confidence']), (1231., 381., .5))
        ios, device, events = self.launch_fixture([rows, rows], window)
        install_phone_unicode_launch_compat(ios, '0.3.2')
        self.assertEqual(device._apps_launch('微信'), '微信')
        self.assertEqual([event for event in events if event[0] == 'tap'], [('tap', 1231., 381.)])
        self.assertNotIn(('press', 'return'), events)

    def test_observed_labels_still_require_query_and_unique_sufficiently_clear_app(self):
        window, rows = self.observed_spotlight()
        for index in (1, 8):  # App label and search field must each be readable.
            weak = [dict(row) for row in rows]
            weak[index]['confidence'] = .3
            self.assertIsNone(_spotlight_app_result(
                weak, window, 'WeChat', {'微信', 'wechat'}, allow_wechat_top_hit=True))
        duplicate = rows + [{**rows[1], 'x': 1350.}]
        with self.assertRaisesRegex(ValueError, 'multiple exact app matches'):
            _spotlight_app_result(duplicate, window, 'WeChat', {'微信', 'wechat'}, allow_wechat_top_hit=True)

    def test_top_hit_fallback_does_not_apply_to_other_unicode_apps(self):
        result = self.spotlight('日历', app='日历')
        result = [row for row in result if row['text'] != 'Apps' and row['y'] != 415]
        result[1] = {**result[1], 'text': '日历'}
        ios, device, events = self.launch_fixture([self.spotlight('旧查询'), result])
        install_phone_unicode_launch_compat(ios, '0.3.2')
        with self.assertRaisesRegex(ValueError, 'did not confirm'):
            device._apps_launch('日历')
        self.assertFalse(any(event[0] == 'tap' for event in events))

    def test_query_field_alone_and_unconfirmed_spotlight_cannot_launch_an_app(self):
        ios, device, events = self.launch_fixture([
            self.spotlight('旧查询'), self.spotlight('WeChat', app='微众银行')])
        install_phone_unicode_launch_compat(ios, '0.3.2')
        with self.assertRaisesRegex(ValueError, 'did not confirm'):
            device._apps_launch('微信')
        self.assertFalse(any(event[0] == 'tap' for event in events))
        ios, device, events = self.launch_fixture([[]])
        install_phone_unicode_launch_compat(ios, '0.3.2')
        with self.assertRaisesRegex(ValueError, 'Spotlight was not confirmed'):
            device._apps_launch('微信')
        self.assertFalse(any(event[0] in ('tap', 'type_text') for event in events))
        self.assertNotIn(('press', 'cmd+a'), events)


class PhoneImageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.data = Path(self.temp.name)
        self.workspace = self.data / 'task/files'
        self.workspace.mkdir(parents=True)
        self.temp_root = self.data / 'temporary'
        self.phone_temp = self.temp_root / 'phone-harness'
        self.phone_temp.mkdir(parents=True)
        temp_root = patch('phone_bridge.tempfile.gettempdir', return_value=str(self.temp_root))
        temp_root.start()
        self.addCleanup(temp_root.stop)
        self.started = time.time() - .01

    @staticmethod
    def image(path, format='PNG'):
        from PIL import Image
        Image.new('RGB', (326, 720), '#e8f5ff').save(path, format)
        return path

    def test_task_source_preserves_pixels_dimensions_and_inspector_boundary(self):
        from worker import workspace_path
        source = self.image(self.workspace / 'original.png')
        result = import_task_screenshot(str(source), self.workspace, self.started)
        self.assertEqual((result['width'], result['height']), (326, 720))
        self.assertEqual(result['coordinate_space'], 'full_image_pixels')
        self.assertIn('image_size=(326, 720)', result['hint'])
        self.assertIn('global Mac screen points', result['hint'])
        copied = workspace_path(self.workspace, result['name'])
        self.assertTrue(copied.name.startswith('phone-'))
        self.assertEqual(copied.read_bytes(), source.read_bytes())
        self.assertEqual(copied.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(ValueError):
            workspace_path(self.workspace, str(self.phone_temp / 'source.png'))

    def test_fresh_temporary_png_jpeg_and_webp_are_supported_without_resizing(self):
        for format, suffix in [('PNG', '.png'), ('JPEG', '.jpg'), ('WEBP', '.webp')]:
            with self.subTest(format=format):
                source = self.image(self.phone_temp / ('source' + suffix), format)
                result = import_task_screenshot(str(source), self.workspace, self.started)
                self.assertEqual((result['width'], result['height']), (326, 720))
                self.assertEqual(Path(result['name']).suffix, suffix)
                self.assertEqual((self.workspace / result['name']).read_bytes(), source.read_bytes())

    def test_unrelated_host_paths_relative_paths_and_traversal_are_rejected(self):
        source = self.image(self.data / 'other-task.png')
        outside = self.image(self.temp_root / 'unrelated.png')
        for path in [str(source), str(outside), 'source.png', str(self.phone_temp / '../unrelated.png')]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                import_task_screenshot(path, self.workspace, self.started)
        self.assertEqual(list(self.workspace.iterdir()), [])

    def test_symlink_file_directory_and_temporary_root_are_rejected(self):
        source = self.image(self.phone_temp / 'source.png')
        leaf = self.phone_temp / 'leaf.png'
        leaf.symlink_to(source)
        nested = self.phone_temp / 'alias'
        nested.symlink_to(self.phone_temp, target_is_directory=True)
        for path in [leaf, nested / 'source.png']:
            with self.subTest(path=path), self.assertRaises((OSError, ValueError)):
                import_task_screenshot(str(path), self.workspace, self.started)
        self.phone_temp.rename(self.temp_root / 'outside')
        self.phone_temp.symlink_to(self.temp_root / 'outside', target_is_directory=True)
        with self.assertRaises((OSError, ValueError)):
            import_task_screenshot(str(self.phone_temp / 'source.png'), self.workspace, self.started)
        self.assertEqual(list(self.workspace.iterdir()), [])

    def test_symlink_destination_is_rejected(self):
        self.workspace.rmdir()
        outside = self.data / 'outside'
        outside.mkdir()
        self.workspace.symlink_to(outside, target_is_directory=True)
        source = self.image(self.phone_temp / 'source.png')
        with self.assertRaises(ValueError):
            import_task_screenshot(str(source), self.workspace, self.started)
        self.assertEqual(list(outside.iterdir()), [])

    def test_stale_invalid_unsupported_oversized_and_nonregular_sources_are_rejected(self):
        old = self.image(self.phone_temp / 'old.png')
        os.utime(old, (self.started - 2, self.started - 2))
        invalid = self.phone_temp / 'invalid.png'
        invalid.write_bytes(b'not an image')
        unsupported = self.image(self.phone_temp / 'animation.gif', 'GIF')
        disguised = self.image(self.phone_temp / 'disguised.png', 'GIF')
        huge = self.phone_temp / 'huge.png'
        with huge.open('wb') as file:
            file.truncate(12_000_001)
        fifo = self.phone_temp / 'fifo.png'
        os.mkfifo(fifo)
        for source in [old, invalid, unsupported, disguised, huge, fifo]:
            with self.subTest(source=source), self.assertRaises((OSError, ValueError)):
                import_task_screenshot(str(source), self.workspace, self.started)
        self.assertEqual(list(self.workspace.iterdir()), [])

    def test_json_result_adds_inspectable_name_and_keeps_original_fields(self):
        source = self.image(self.phone_temp / 'source.png')
        payload = {'success': True, 'output': str(source), 'screenshots': [str(source)],
                   'exit_code': 0, 'workspace': 'official-workspace'}
        result = json.loads(normalize_phone_images(json.dumps(payload), self.workspace, self.started))
        self.assertEqual({key: result[key] for key in payload}, payload)
        self.assertEqual(len(result['task_images']), 1)
        self.assertTrue((self.workspace / result['task_images'][0]['name']).is_file())
        self.assertNotIn('image_import_errors', result)

    def test_native_vision_protocol_updates_all_text_without_altering_image_content(self):
        source = self.image(self.phone_temp / 'source.png')
        payload = {'success': True, 'output': str(source), 'screenshots': [str(source)]}
        summary = json.dumps(payload)
        suffix = '\n\nThe screenshot from this call is attached — inspect it with your native vision.'
        image_block = {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,fixture'}}
        original = {'_multimodal': True, 'text_summary': summary,
                    'meta': {'screenshot_path': str(source), 'native_vision': True},
                    'content': [{'type': 'text', 'text': summary + suffix}, image_block]}
        result = normalize_phone_images(original, self.workspace, self.started)
        additions = result['task_images']
        self.assertEqual(len(additions), 1)  # screenshots and meta refer to one file.
        parsed = json.loads(result['text_summary'])
        self.assertEqual(parsed['task_images'], additions)
        self.assertEqual(result['meta']['task_images'], additions)
        self.assertEqual(result['content'][0]['text'], result['text_summary'] + suffix)
        self.assertIs(result['content'][1], image_block)
        self.assertEqual(original['text_summary'], summary)
        self.assertNotIn('task_images', original['meta'])
        self.assertNotIn('task_images', original)
        self.assertEqual(parsed['screenshots'], payload['screenshots'])

    def test_metadata_only_prose_summary_and_plain_dict_remain_compatible(self):
        source = self.image(self.phone_temp / 'source.png')
        original = {'_multimodal': True, 'text_summary': 'Original upstream status',
                    'meta': {'screenshot_path': str(source)}, 'content': []}
        result = normalize_phone_images(original, self.workspace, self.started)
        self.assertTrue(result['text_summary'].startswith('Original upstream status\n\n'))
        self.assertEqual(len(result['task_images']), 1)
        self.assertEqual(json.loads(result['content'][0]['text'])['task_images'], result['task_images'])
        plain = {'success': True, 'screenshots': [str(source)], 'output': 'original'}
        result = normalize_phone_images(plain, self.workspace, self.started)
        self.assertEqual(result['output'], 'original')
        self.assertEqual(len(result['task_images']), 1)
        for unchanged in ['plain upstream error', '[]', {'success': False, 'error': 'BLOCKED'}]:
            self.assertIs(normalize_phone_images(unchanged, self.workspace, self.started), unchanged)

    def test_untrusted_image_does_not_change_an_already_successful_action(self):
        source = self.image(self.data / 'private.png')
        payload = {'success': True, 'output': 'action already completed', 'screenshots': [str(source)]}
        result = json.loads(normalize_phone_images(json.dumps(payload), self.workspace, self.started))
        self.assertTrue(result['success'])
        self.assertEqual(result['output'], payload['output'])
        self.assertEqual(result['task_images'], [])
        self.assertTrue(result['image_import_errors'])
        self.assertEqual(list(self.workspace.iterdir()), [])


class FakeHermes:
    def __init__(self):
        self.interactive = contextvars.ContextVar('fake_interactive', default=False)
        self.callback = threading.local()
        self.context = types.ModuleType('tools.approval_context')
        self.context.set_hermes_interactive_context = self.interactive.set
        self.context.reset_hermes_interactive_context = self.interactive.reset
        self.terminal = types.ModuleType('tools.terminal_tool')
        self.terminal._get_approval_callback = lambda: getattr(self.callback, 'value', None)
        self.terminal.set_approval_callback = lambda value: setattr(self.callback, 'value', value)

    def modules(self):
        return {'tools': types.ModuleType('tools'),
                'tools.approval_context': self.context, 'tools.terminal_tool': self.terminal}

    def pipeline(self, executed):
        def run(args):
            if not self.interactive.get():
                raise AssertionError('native callback must be interactive, without a CLI prompt')
            callback = self.terminal._get_approval_callback()
            decision = callback('<phone_exec> (plugin approval rule)', 'upstream short summary', allow_permanent=True)
            if decision != 'once':
                return json.dumps({'success': False, 'error': 'BLOCKED: user did not approve'})
            executed.append(args)
            return json.dumps({'success': True, 'output': 'fixture only'})
        return run


class PhoneExecutionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.data = Path(self.temp.name)
        self.events = []
        self.pending = {}
        self.hermes = FakeHermes()
        self.patcher = patch.dict(sys.modules, self.hermes.modules())
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def emit(self, kind, **data):
        self.events.append((kind, data))
        if kind == 'approval':
            self.pending.update(data)

    def gate(self, decision='approve', *, auto=False):
        def reply(_):
            return {'approval_id': self.pending['approval_id'],
                    'action_hash': self.pending['action_hash'], 'decision': decision}
        return ApprovalGate(self.emit, reply, timeout=1, auto_approve=auto)

    def bridge(self, **kwargs):
        return PhoneBridge(self.data, self.data / 'tasks/fixture', self.gate(), self.emit, **kwargs)

    def test_manual_approval_displays_complete_code_and_restores_callbacks(self):
        executed = []
        bridge = self.bridge()
        code = '# task: fixture\n' + '# long comment\n' * 40 + 'print("完整代码")'
        result = bridge.middleware(tool_name='phone_exec', args={'code': code},
                                   next_call=self.hermes.pipeline(executed))
        self.assertTrue(json.loads(result)['success'])
        self.assertEqual(executed, [{'code': code}])
        card = next(data for kind, data in self.events if kind == 'approval')
        self.assertEqual(json.loads(card['details'])['source'], code)
        self.assertFalse(self.hermes.interactive.get())
        self.assertIsNone(self.hermes.terminal._get_approval_callback())

    def test_approved_pipeline_imports_its_fresh_screenshot_for_inspection(self):
        from PIL import Image
        bridge = self.bridge()
        executed = []
        official = self.hermes.pipeline(executed)
        def screenshot(args):
            result = json.loads(official(args))
            source = bridge.task_dir / 'files/source.png'
            source.parent.mkdir(parents=True)
            Image.new('RGB', (326, 720), 'white').save(source)
            result['screenshots'] = [str(source)]
            return json.dumps(result)
        code = 'print(screenshot())'
        result = json.loads(bridge.middleware(tool_name='phone_exec', args={'code': code}, next_call=screenshot))
        self.assertEqual(executed, [{'code': code}])
        self.assertTrue(result['success'])
        self.assertEqual(result['task_images'][0]['width'], 326)
        self.assertTrue((bridge.task_dir / 'files' / result['task_images'][0]['name']).exists())
        card = next(data for kind, data in self.events if kind == 'approval')
        self.assertEqual(json.loads(card['details'])['source'], code)

    def test_unexpected_image_adapter_failure_keeps_original_action_result(self):
        bridge = self.bridge()
        original = json.dumps({'success': True, 'output': 'already done'})
        with patch('phone_bridge.normalize_phone_images', side_effect=RuntimeError('fixture import failure')):
            result = bridge.middleware(tool_name='phone_exec', args={'code': 'print(1)'},
                                       next_call=lambda args: original)
        self.assertIs(result, original)

    def test_migrated_workspace_import_uses_physical_folder_not_legacy_alias(self):
        from PIL import Image
        workspace = self.data / 'PicoFiles/Tasks/fixture'
        workspace.mkdir(parents=True)
        bridge = self.bridge(workspace=workspace)
        legacy = bridge.task_dir / 'files'
        legacy.parent.mkdir(parents=True)
        legacy.symlink_to(workspace)
        executed = []
        official = self.hermes.pipeline(executed)
        def screenshot(args):
            result = json.loads(official(args))
            source = workspace / 'source.png'
            Image.new('RGB', (326, 720), 'white').save(source)
            result['screenshots'] = [str(source)]
            return json.dumps(result)
        result = json.loads(bridge.middleware(tool_name='phone_exec', args={'code': 'print(screenshot())'}, next_call=screenshot))
        self.assertTrue(result['success'])
        self.assertTrue((workspace / result['task_images'][0]['name']).is_file())
        self.assertEqual(result['task_images'][0]['width'], 326)
        self.assertTrue(legacy.is_symlink())

    def test_manual_denial_stops_execution_and_retries(self):
        executed = []
        bridge = self.bridge()
        bridge.gate = self.gate('deny')
        for _ in range(2):
            result = bridge.middleware(tool_name='phone_exec', args={'code': 'print(1)'},
                                       next_call=self.hermes.pipeline(executed))
            self.assertFalse(json.loads(result)['success'])
        self.assertEqual(executed, [])
        self.assertEqual([kind for kind, _ in self.events].count('approval'), 1)

    def test_automatic_mode_uses_native_policy_without_prompt(self):
        executed = []
        bridge = self.bridge()
        bridge.gate = self.gate(auto=True)
        for code in ['print(1)', 'print(2)']:
            result = bridge.middleware(tool_name='phone_exec', args={'code': code},
                                       next_call=self.hermes.pipeline(executed))
            self.assertTrue(json.loads(result)['success'])
        self.assertEqual(len(executed), 2)
        self.assertEqual([kind for kind, _ in self.events], ['auto_approved', 'auto_approved'])

    def test_cancel_before_execution_and_during_approval_are_closed(self):
        for during in (False, True):
            executed = []
            bridge = self.bridge()
            if during:
                bridge.gate.ask = lambda action, context: (bridge.cancel(), action)[1]
            else:
                bridge.cancel()
            result = bridge.middleware(tool_name='phone_exec', args={'code': 'print(1)'},
                                       next_call=self.hermes.pipeline(executed))
            self.assertFalse(json.loads(result)['success'])
            self.assertEqual(executed, [])

    def test_no_adapter_exception_falls_through_to_execution(self):
        executed = []
        bridge = self.bridge()
        bridge.gate.ask = lambda *args: (_ for _ in ()).throw(RuntimeError('fixture failure'))
        result = bridge.middleware(tool_name='phone_exec', args={'code': 'print(1)'},
                                   next_call=self.hermes.pipeline(executed))
        self.assertFalse(json.loads(result)['success'])
        self.assertEqual(executed, [])

    def test_unrelated_tools_and_feed_are_isolated(self):
        bridge = self.bridge(enabled=False)
        calls = []
        self.assertEqual(bridge.middleware(tool_name='read_document', args={},
                                          next_call=lambda args: calls.append(args) or 'unchanged'), 'unchanged')
        self.assertEqual(calls, [{}])
        result = bridge.middleware(tool_name='phone_exec', args={}, next_call=lambda args: self.fail('disabled'))
        self.assertFalse(json.loads(result)['success'])
        self.assertEqual(bridge.toolsets(), ['telos', 'skills'])
        self.assertEqual(bridge.toolsets(feed=True), ['telos'])
        bridge.enabled = True
        self.assertEqual(bridge.toolsets(), ['telos', 'skills', 'phone-harness'])
        self.assertEqual(bridge.toolsets(feed=True), ['telos'])

    def test_callback_cannot_approve_a_different_tool_or_missing_payload(self):
        bridge = self.bridge()
        self.assertEqual(bridge.approve('<phone_exec> (plugin approval rule)', ''), 'deny')
        token = bridge._args.set({'code': 'print(1)'})
        try:
            self.assertEqual(bridge.approve('<other_tool> (plugin approval rule)', ''), 'deny')
        finally:
            bridge._args.reset(token)
        self.assertEqual(self.events, [])

    def test_lock_is_cross_process_and_released_after_child_exit(self):
        backend = str(Path(__file__).resolve().parents[1] / 'Backend')
        script = '''import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from phone_bridge import PhoneBridge
b=PhoneBridge(Path(sys.argv[2]),Path(sys.argv[2])/'child',None,lambda *a,**k:None)
with b.exclusive():
    print('locked',flush=True)
    sys.stdin.readline()
'''
        child = subprocess.Popen([sys.executable, '-c', script, backend, str(self.data)],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), 'locked')
            bridge = self.bridge(lock_timeout=.03)
            with self.assertRaises(PhoneBusy):
                with bridge.exclusive():
                    self.fail('two task processes must not own the phone')
            child.communicate('\n', timeout=5)
            self.assertEqual(child.returncode, 0)
            with bridge.exclusive():
                pass
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate()

    def test_cancel_releases_waiting_lock_promptly(self):
        owner = self.bridge()
        waiting = self.bridge(lock_timeout=5)
        results = []
        started = threading.Event()
        def wait():
            started.set()
            try:
                with waiting.exclusive():
                    results.append('incorrectly acquired')
            except PhoneCancelled:
                results.append('cancelled')
        with owner.exclusive():
            thread = threading.Thread(target=wait)
            thread.start()
            self.assertTrue(started.wait(1))
            waiting.cancel()
            thread.join(1)
            self.assertFalse(thread.is_alive())
        self.assertEqual(results, ['cancelled'])


if __name__ == '__main__':
    unittest.main()
