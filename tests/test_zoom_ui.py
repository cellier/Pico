"""Zoom UI commit boundary against an isolated fake Mac, never a real account."""
import copy
from contextlib import closing
import fcntl
import json
import math
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from mac_bridge import ApprovalGate, MacBridge
from zoom_connector import ZoomError
from zoom_documents import OperationJournal
from zoom_ui import ZoomUICommit, register_zoom_ui


class FakeAX:
    def __init__(self, mac):
        self.mac = mac

    def perform(self, index, action):
        self.mac.issue('ax_press', {'element_index': index, 'action': action})

    def set(self, index, attribute, text):
        self.mac.issue('ax_set', {'element_index': index, 'attribute': attribute, 'text': text})


class FakeMac:
    def __init__(self, folder):
        self.folder = Path(folder)
        self.content = 'Private fixture Zoom Slides editor; saved title: Test deck'
        self.calls = []
        self.ax = FakeAX(self)
        self.failure = None

    def list_apps(self):
        return [{'name': 'Fixture browser', 'pid': 55, 'bundle_id': 'com.example.fixture', 'path': '/fixture'},
                {'name': 'Pico', 'pid': 56, 'bundle_id': 'com.telos.mac', 'path': '/pico'}]

    def permissions(self):
        return {}

    def get_app_state(self, *args, **kwargs):
        return {'app': self.list_apps()[0],
                'nodes': [{'element_index': 1, 'role': 'AXButton', 'title': self.content}],
                'windows': [{'title': self.content}], 'text': self.content}

    def see(self, *args, **kwargs):
        path = self.folder / (uuid.uuid4().hex + '.png')
        path.write_bytes(b'private fake pixels; never inspected or emitted')
        return {'path': str(path), 'width': 200, 'height': 120}

    def issue(self, kind, values):
        self.calls.append((kind, copy.deepcopy(values)))
        if self.failure:
            raise self.failure
        return None

    def key(self, key, **kwargs):
        return self.issue('key', dict(key=key, **kwargs))

    def click(self, x, y, **kwargs):
        return self.issue('click', dict(x=x, y=y, **kwargs))

    def type(self, text, **kwargs):
        return self.issue('type', dict(text=text, **kwargs))


class ZoomUITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.data = Path(self.temp.name)
        self.events = []
        self.pending = {}
        self.decision = 'approve'
        self.on_approval = None

        def emit(kind, **data):
            self.events.append((kind, copy.deepcopy(data)))
            if kind == 'approval':
                self.pending = copy.deepcopy(data)
                if self.on_approval:
                    self.on_approval(data)

        def reply(_timeout):
            return {'approval_id': self.pending['approval_id'], 'action_hash': self.pending['action_hash'],
                    'decision': self.decision}

        self.emit = emit
        self.gate = ApprovalGate(emit, reply)
        self.native = FakeMac(self.data)
        self.mac = MacBridge(self.data, self.data / 'task', emit, self.gate, self.native)
        self.ui = ZoomUICommit(self.data, self.mac)

    def tearDown(self):
        self.temp.cleanup()

    def request(self, kind='key', **changes):
        observation = self.mac.observe({'app': 'Fixture browser', 'screenshot': kind == 'click'})
        action = {'app': 'Fixture browser', 'observation_id': observation['observation_id'], 'kind': kind}
        action.update({'key': 'cmd+return'} if kind == 'key' else
                      {'element_index': 1} if kind == 'ax_press' else
                      {'text': 'Exact original fixture text.'} if kind == 'type' else
                      {'text': 'Exact original fixture text.', 'element_index': 1} if kind == 'ax_set' else
                      {'x': 32, 'y': 42})
        value = {'product': 'slides', 'operation': 'create',
                 'target': {'account': 'pico-fixture@example.invalid', 'resource': 'private-folder-id',
                            'url': 'https://slides.zoom.us/fixture/editor'},
                 'expected': {'title': 'Test deck', 'body': 'Exact original fixture text.'},
                 'action': action, 'operation_id': str(uuid.uuid4()),
                 'reason': 'Create only the private fixture deck in the verified Zoom Slides account.'}
        value.update(changes)
        return value

    def row(self, operation):
        with closing(sqlite3.connect(self.data / 'zoom-doc-operations.sqlite')) as db:
            return db.execute('SELECT state,result FROM operations WHERE id=?', (operation,)).fetchone()

    def assert_zoom_error(self, state, callback):
        with self.assertRaises(ZoomError) as caught:
            callback()
        self.assertEqual(caught.exception.state, state)
        return caught.exception

    def test_all_short_atomic_kinds_use_real_native_gate_and_never_claim_cloud_success(self):
        for kind in ('key', 'click', 'ax_press'):
            with self.subTest(kind=kind):
                request = self.request(kind, expected={'title': 'Test ' + kind})
                outcome = self.ui.commit(request)
                self.assertTrue(outcome['submitted'])
                self.assertFalse(outcome['verified'])
                self.assertEqual(outcome['state'], 'ui_submitted')
                self.assertNotIn('committed', outcome)
                self.assertIn('reopen', outcome['notice'])
                self.assertEqual(self.native.calls[-1][0], kind)
                approval = [data for name, data in self.events if name == 'approval'][-1]
                reviewed = json.loads(approval['details'])
                self.assertEqual(reviewed['zoom_ui'], {key: request[key] for key in
                                                      ('product', 'operation', 'target', 'expected', 'operation_id')})
                self.assertEqual(self.row(request['operation_id'])[0], 'ui_submitted')
        self.assertEqual(len(self.native.calls), 3)
        self.assertEqual(sum(name == 'approval' for name, _ in self.events), 3)

    def test_same_id_returns_saved_submission_after_restart_without_another_app_action(self):
        request = self.request()
        self.ui.commit(request)
        self.native.content = 'A different page now; no resubmission allowed.'
        request['action']['observation_id'] = 'a-different-observation'
        request['action']['key'] = 'return'
        reopened = ZoomUICommit(self.data, self.mac)
        outcome = reopened.commit(request)
        self.assertTrue(outcome['submitted'])
        self.assertTrue(outcome['replayed'])
        self.assertFalse(outcome['verified'])
        self.assertEqual(len(self.native.calls), 1)
        self.assertEqual(sum(name == 'approval' for name, _ in self.events), 1)

    def test_issued_intent_cannot_be_repeated_by_changing_id_coordinates_key_or_current_url(self):
        request = self.request('click')
        self.ui.commit(request)
        for mode in ('coordinates', 'key', 'url', 'reason', 'account_case'):
            with self.subTest(mode=mode):
                changed = self.request('click')
                if mode == 'coordinates':
                    changed['action'].update(x=180, y=70)
                elif mode == 'key':
                    changed['action'] = self.request('key')['action']
                elif mode == 'url':
                    changed['target']['url'] = 'https://slides.zoom.us/fixture/editor#new-selection'
                elif mode == 'reason':
                    changed['reason'] = 'A different explanation must not change the same intended commit.'
                else:
                    changed['target']['account'] = 'PICO-Fixture@EXAMPLE.INVALID'
                self.assert_zoom_error('outcome_unknown', lambda: self.ui.commit(changed))
        self.assertEqual(len(self.native.calls), 1)

    def test_same_id_different_stable_content_or_target_is_a_conflict(self):
        request = self.request()
        self.ui.commit(request)
        for field in ('expected', 'resource', 'product', 'operation'):
            changed = copy.deepcopy(request)
            if field == 'expected': changed['expected']['body'] = 'Changed original text.'
            elif field == 'resource': changed['target']['resource'] = 'another-private-folder'
            elif field == 'product': changed['product'] = 'paper'
            else: changed['operation'] = 'update'
            self.assert_zoom_error('operation_conflict', lambda: self.ui.commit(changed))
        self.assertEqual(len(self.native.calls), 1)

    def test_different_exact_requested_change_with_a_new_id_is_not_silently_blocked(self):
        self.ui.commit(self.request())
        changed = self.request(expected={'title': 'A genuinely different fixture deck'})
        self.assertTrue(self.ui.commit(changed)['submitted'])
        self.assertEqual(len(self.native.calls), 2)

    def test_uncertain_issued_action_is_durable_and_cannot_be_resent_with_another_id(self):
        request = self.request()
        self.native.failure = TimeoutError('Fixture acknowledgement was lost after key dispatch')
        self.assert_zoom_error('outcome_unknown', lambda: self.ui.commit(request))
        self.assertEqual(self.row(request['operation_id'])[0], 'outcome_unknown')
        self.native.failure = None
        reopened = ZoomUICommit(self.data, self.mac)
        self.assert_zoom_error('outcome_unknown', lambda: reopened.commit(request))
        changed = self.request('ax_press')
        self.assert_zoom_error('outcome_unknown', lambda: reopened.commit(changed))
        self.assertEqual(len(self.native.calls), 1)

    def test_denied_stale_and_busy_never_claim_or_report_a_submission(self):
        request = self.request()
        self.decision = 'deny'
        outcome = self.ui.commit(request)
        self.assertFalse(outcome['submitted'])
        self.assertEqual(outcome['state'], 'denied')
        self.assertIsNone(self.row(request['operation_id']))

        self.decision = 'approve'
        request = self.request(expected={'title': 'Stale fixture'})
        self.on_approval = lambda _data: setattr(self.native, 'content', 'The target changed during approval')
        outcome = self.ui.commit(request)
        self.assertFalse(outcome['submitted'])
        self.assertEqual(outcome['state'], 'stale')
        self.assertIsNone(self.row(request['operation_id']))

        self.on_approval = None
        request = self.request(expected={'title': 'Busy fixture'})
        with (self.data / 'mac-execution.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            outcome = self.ui.commit(request)
        self.assertFalse(outcome['submitted'])
        self.assertEqual(outcome['state'], 'busy')
        self.assertIsNone(self.row(request['operation_id']))
        self.assertEqual(self.native.calls, [])

    def test_invalidated_approval_does_not_submit(self):
        request = self.request()
        self.on_approval = lambda _data: self.gate.invalidate_pending()
        outcome = self.ui.commit(request)
        self.assertFalse(outcome['submitted'])
        self.assertEqual(self.native.calls, [])
        self.assertIsNone(self.row(request['operation_id']))

    def test_final_generation_check_after_claim_fails_before_native_action(self):
        request = self.request()
        original = ZoomUICommit._claim

        def claim(*values):
            result = original(*values)
            self.gate.invalidate_pending()
            return result

        with patch.object(ZoomUICommit, '_claim', side_effect=claim):
            with self.assertRaises(ValueError):
                self.ui.commit(request)
        self.assertEqual(self.native.calls, [])
        self.assertEqual(self.row(request['operation_id'])[0], 'failed')
        self.assert_zoom_error('superseded', lambda: self.ui.commit(request))

    def test_modified_native_approval_cannot_change_target_content_or_action(self):
        self.gate.auto_approve = True
        ask = self.gate.ask
        for field in ('product', 'expected', 'key', 'pid', 'extra'):
            request = self.request(expected={'title': 'Exact approval ' + field})

            def changed(action, context):
                exact = ask(action, context)
                if field == 'product': exact['zoom_ui']['product'] = 'paper'
                elif field == 'expected': exact['zoom_ui']['expected']['title'] = 'Unexpected title'
                elif field == 'key': exact['key'] = 'return'
                elif field == 'pid': exact['pid'] = 56
                else: exact['source'] = 'Never execute a source field here'
                return exact

            with patch.object(self.gate, 'ask', side_effect=changed):
                self.assert_zoom_error('invalid_approval', lambda: self.ui.commit(request))
            self.assertIsNone(self.row(request['operation_id']))
        self.assertEqual(self.native.calls, [])

    def test_real_mac_guard_still_blocks_own_app_missing_observation_and_outside_coordinates(self):
        for mode in ('own_app', 'missing_observation', 'outside_coordinates'):
            request = self.request('click', expected={'title': 'Guard ' + mode})
            if mode == 'own_app': request['action']['app'] = 'Pico'
            elif mode == 'missing_observation': request['action']['observation_id'] = 'not-current'
            else: request['action']['x'] = 5000
            with self.assertRaises(ValueError):
                self.ui.commit(request)
            self.assertIsNone(self.row(request['operation_id']))
        self.assertEqual(self.native.calls, [])

    def test_strict_action_and_target_reject_scripts_batches_extra_fields_and_navigation(self):
        original = self.request()
        invalid = []
        for kind in ('python', 'applescript', 'type', 'scroll'):
            value = copy.deepcopy(original)
            value['action']['kind'] = kind
            invalid.append(value)
        for key, item in (('source', 'print(1)'), ('text', 'send this'), ('x', 5), ('safe', True), ('risk', 'read')):
            value = copy.deepcopy(original)
            value['action'][key] = item
            invalid.append(value)
        for key in ('cmd+f', 'escape', 'tab', 'return\nreturn', 'cmd+return;return'):
            value = copy.deepcopy(original)
            value['action']['key'] = key
            invalid.append(value)
        for target in ({'account': 'x', 'resource': 'y', 'password': 'not-allowed'},
                       {'resource': 'missing-account'}, {'account': '', 'resource': 'x'},
                       {'account': 'a', 'resource': 'x', 'url': 'https://user:secret@example.invalid/'}):
            invalid.append(dict(original, target=target))
        for value in invalid:
            with self.subTest(value=value):
                self.assert_zoom_error('invalid_argument', lambda: self.ui.commit(value))
        self.assertEqual(self.native.calls, [])
        self.assertEqual(self.events, [])

    def test_bad_expected_json_and_non_finite_coordinates_are_rejected(self):
        invalid = [self.request(expected={}), self.request(expected={'text': 'x' * 1000001}),
                   self.request(expected={'number': math.nan}), self.request(expected={'not_json': object()})]
        for coordinate in (math.inf, math.nan, True):
            value = self.request('click')
            value['action']['x'] = coordinate
            invalid.append(value)
        for value in invalid:
            self.assert_zoom_error('invalid_argument', lambda: self.ui.commit(value))
        self.assertEqual(self.native.calls, [])

    def test_schema_factory_registers_exact_tool_without_touching_gateway(self):
        registered = {}

        def register(name, description, properties, required, handler):
            registered[name] = (description, properties, required, handler)

        result = register_zoom_ui(register, lambda text: {'type': 'string', 'description': text}, self.data, self.mac)
        self.assertIsInstance(result, ZoomUICommit)
        self.assertEqual(set(registered), {'zoom_ui_commit'})
        description, properties, required, handler = registered['zoom_ui_commit']
        self.assertEqual(set(required), set(properties))
        self.assertFalse(properties['action']['additionalProperties'])
        self.assertEqual(properties['action']['properties']['kind']['enum'], ['click', 'ax_press', 'key', 'type', 'ax_set'])
        self.assertIn('never that a cloud save succeeded', description)
        self.assertTrue(handler(self.request())['submitted'])

    def test_autosaved_type_and_ax_set_are_single_submissions_with_exact_text_and_safe_replay(self):
        for kind in ('type', 'ax_set'):
            with self.subTest(kind=kind):
                text = 'Exact original autosave text: 中文 and English, @literal URL.\n' + kind
                request = self.request(kind, product='paper', operation='update',
                                       expected={'change': {'inserted_text': text}})
                request['action']['text'] = text
                outcome = self.ui.commit(request)
                self.assertTrue(outcome['submitted'])
                self.assertFalse(outcome['verified'])
                self.assertEqual(self.native.calls[-1][0], kind)
                self.assertEqual(self.native.calls[-1][1]['text'], text)
                if kind == 'ax_set':
                    self.assertEqual(self.native.calls[-1][1]['attribute'], 'AXValue')
                self.assertTrue(ZoomUICommit(self.data, self.mac).commit(request)['replayed'])
                new_id = self.request(kind, product='paper', operation='update', expected=request['expected'])
                new_id['action']['text'] = text
                self.assert_zoom_error('outcome_unknown', lambda: self.ui.commit(new_id))
        self.assertEqual(len(self.native.calls), 2)

    def test_autosaved_text_must_equal_a_complete_expected_scalar_not_a_paraphrase_or_substring(self):
        for kind in ('type', 'ax_set'):
            for mode in ('different', 'substring', 'key_only', 'too_long', 'extra_field'):
                with self.subTest(kind=kind, mode=mode):
                    request = self.request(kind)
                    if mode == 'different': request['expected'] = {'text': 'A paraphrase is not the submitted original.'}
                    elif mode == 'substring': request['expected'] = {'text': 'Prefix ' + request['action']['text'] + ' suffix'}
                    elif mode == 'key_only': request['expected'] = {request['action']['text']: 'Not the value'}
                    elif mode == 'extra_field': request['action']['source'] = 'Never a script'
                    else:
                        request['action']['text'] = 'x' * 160001
                        request['expected'] = {'text': request['action']['text']}
                    self.assert_zoom_error('invalid_argument', lambda: self.ui.commit(request))
        self.assertEqual(self.native.calls, [])

    def test_full_text_unicode_limit_is_not_silently_truncated(self):
        text = '白' * 160000
        request = self.request('type', expected={'text': text})
        request['action']['text'] = text
        self.assertTrue(self.ui.commit(request)['submitted'])
        self.assertEqual(self.native.calls[0][1]['text'], text)

    def test_intent_claim_is_atomic_between_separate_connections(self):
        OperationJournal(self.data).close()
        barrier = threading.Barrier(2)
        outcomes = []

        def claim():
            journal = OperationJournal(self.data)
            try:
                barrier.wait(timeout=3)
                ZoomUICommit._claim(journal, str(uuid.uuid4()), 'same-private-intent', 'same-ui-account')
                outcomes.append('claimed')
            except ZoomError as error:
                outcomes.append(error.state)
            finally:
                journal.close()

        threads = [threading.Thread(target=claim) for _ in range(2)]
        for thread in threads: thread.start()
        for thread in threads: thread.join(timeout=5)
        self.assertEqual(sorted(outcomes), ['claimed', 'outcome_unknown'])
        self.assertFalse(any(thread.is_alive() for thread in threads))

    def test_journal_stores_intent_hashes_not_submitted_body_or_account(self):
        request = self.request()
        self.ui.commit(request)
        content = (self.data / 'zoom-doc-operations.sqlite').read_bytes()
        self.assertNotIn(request['expected']['body'].encode(), content)
        self.assertNotIn(request['target']['account'].encode(), content)
        self.assertEqual((self.data / 'zoom-doc-operations.sqlite').stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
