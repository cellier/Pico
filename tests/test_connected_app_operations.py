"""Connected-app authorization and replay tests; never contact a real service."""
import copy
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import stat
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from register_connected_apps import AppOperationError, AppOperations


READ = 'connectors__gmail__get_message'
WRITE = 'connectors__gmail__send_message'
DELETE = 'connectors__gmail__delete_message'
UNKNOWN = 'connectors__gmail__unknown_action'
ACCOUNT = {'alias': 'fixture-account', 'label': 'fixture@example.invalid',
           'status': 'connected', 'active': True, 'retired': False}


class FakeBridge:
    def __init__(self, events):
        self.events = events
        read_schema = {'type': 'object', 'required': ['message_id'],
                       'properties': {'message_id': {'type': 'string', 'minLength': 1}},
                       'additionalProperties': False}
        write_schema = {
            'type': 'object', 'required': ['recipient', 'body', 'options'],
            'properties': {
                'recipient': {'type': 'string', 'const': 'fixture@example.invalid'},
                'body': {'type': 'string', 'minLength': 1, 'maxLength': 1000},
                'options': {'type': 'object', 'required': ['mode'],
                            'properties': {'mode': {'enum': ['plain']},
                                           'labels': {'type': 'array', 'maxItems': 2,
                                                      'items': {'type': 'string'}}},
                            'additionalProperties': False},
            }, 'additionalProperties': False,
        }
        self.metadata = {
            READ: {'parameters': read_schema, 'facet': 'read', 'accounts': [ACCOUNT]},
            WRITE: {'parameters': write_schema, 'facet': 'write', 'accounts': [ACCOUNT]},
            DELETE: {'parameters': read_schema, 'facet': 'destructive', 'accounts': [ACCOUNT]},
            UNKNOWN: {'parameters': write_schema, 'facet': 'unclassified', 'accounts': [ACCOUNT]},
        }
        self.calls = []
        self.connections = []
        self.result = {'result': {'id': 'fixture-result'}, 'submitted': True, 'verified': True}
        self.failure = None

    def describe(self, request):
        self.events.append(('describe', copy.deepcopy(request)))
        return {'tools': {name: copy.deepcopy(self.metadata[name]) for name in request['names']
                          if name in self.metadata}}

    def call(self, request):
        self.events.append(('call', copy.deepcopy(request)))
        self.calls.append(copy.deepcopy(request))
        if self.failure:
            raise self.failure
        return copy.deepcopy(self.result)

    def connect(self, request):
        self.events.append(('connect', copy.deepcopy(request)))
        self.connections.append(copy.deepcopy(request))
        return {'apps': [{'id': 'gmail', 'state': 'connecting'}]}


class CancelledFixture(RuntimeError):
    pass


class FakeGate:
    def __init__(self, events):
        self.events = events
        self.generation = 7
        self.asks = []
        self.decision = 'approve'
        self.on_ask = None
        self.checks = 0
        self.cancel_on_check = None

    def check_execution(self, generation):
        self.checks += 1
        self.events.append(('check', generation))
        if self.cancel_on_check == self.checks or generation != self.generation:
            raise CancelledFixture('The fixture task was cancelled.')

    def ask(self, action, context):
        self.events.append(('ask', copy.deepcopy(action)))
        self.asks.append((copy.deepcopy(action), copy.deepcopy(context)))
        if self.on_ask:
            self.on_ask(action, context)
        if self.decision == 'deny':
            return None
        if self.decision == 'changed':
            action['arguments']['body'] = 'A different message that was not reviewed.'
        return action


class ConnectedAppOperationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.data = Path(self.temp.name) / 'private-data'
        self.events = []
        self.bridge = FakeBridge(self.events)
        self.gate = FakeGate(self.events)
        self.operations = AppOperations(self.data, self.bridge, self.gate)

    def tearDown(self):
        self.temp.cleanup()

    def request(self, **changes):
        value = {'name': WRITE, 'arguments': {'recipient': 'fixture@example.invalid',
                                            'body': 'Exact private fixture text.\n第二行。',
                                            'options': {'mode': 'plain', 'labels': ['fixture']}},
                 'operation_id': 'fixture-op-0001',
                 'reason': 'Send only the exact user-requested fixture text to the fixture account.'}
        value.update(changes)
        return value

    def assert_app_error(self, state, callback):
        with self.assertRaises(AppOperationError) as caught:
            callback()
        self.assertEqual(caught.exception.state, state)
        return caught.exception

    def row(self, operation='fixture-op-0001'):
        path = self.data / 'connected-app-operations.sqlite'
        if not path.exists():
            return None
        with closing(sqlite3.connect(path)) as db:
            return db.execute('SELECT fingerprint,state,result FROM operations WHERE id=?',
                              (operation,)).fetchone()

    def reopened(self):
        return AppOperations(self.data, self.bridge, self.gate)

    def test_read_uses_exact_current_schema_and_never_requests_write_approval(self):
        request = {'name': READ, 'arguments': {'message_id': 'fixture-message-id'}}
        result = self.operations.read(request)
        self.assertEqual(self.bridge.calls, [dict(request, expected_contract=self.bridge.metadata[READ])])
        self.assertEqual(self.gate.asks, [])
        self.assertFalse(self.data.exists())
        self.assertEqual(result['result']['id'], 'fixture-result')
        self.assertEqual([event for event, _ in self.events], ['describe', 'call'])

    def test_read_rejects_writes_destructive_and_unclassified_tools(self):
        for name in (WRITE, DELETE, UNKNOWN):
            with self.subTest(name=name):
                self.assert_app_error('operation_mismatch',
                                      lambda: self.operations.read(self.request(name=name)))
        self.assertEqual(self.bridge.calls, [])
        self.assertEqual(self.gate.asks, [])

    def test_absent_or_missing_facet_is_not_guessed_from_tool_name(self):
        self.assert_app_error('unavailable', lambda: self.operations.read(
            {'name': 'connectors__gmail__nonexistent', 'arguments': {}}))
        del self.bridge.metadata[READ]['facet']
        self.assert_app_error('operation_mismatch', lambda: self.operations.read(
            {'name': READ, 'arguments': {'message_id': 'fixture'}}))
        self.assertEqual(self.bridge.calls, [])

    def test_read_name_and_parameters_are_checked_before_any_execution(self):
        for name in ('send_message', 'connectors__gmail__send_message;execute',
                     'connectors__gmail__', '', None):
            with self.subTest(name=name):
                self.assert_app_error('invalid_argument', lambda: self.operations.read(
                    {'name': name, 'arguments': {}}))
        for args in (None, [], {'message_id': 42}, {'message_id': ''},
                     {'message_id': 'fixture', 'extra': 'must not silently drop'}):
            with self.subTest(args=args):
                self.assert_app_error('invalid_argument', lambda: self.operations.read(
                    {'name': READ, 'arguments': args}))
        self.assertEqual(self.bridge.calls, [])

    def test_write_fails_closed_without_authorization_context(self):
        operations = AppOperations(self.data, self.bridge, None)
        self.assert_app_error('approval_unavailable', lambda: operations.write(self.request()))
        self.assertEqual(self.events, [])

    def test_write_refuses_read_and_unclassified_facets_before_review(self):
        for name in (READ, UNKNOWN):
            with self.subTest(name=name):
                self.assert_app_error('operation_mismatch',
                                      lambda: self.operations.write(self.request(name=name)))
        self.assertEqual(self.bridge.calls, [])
        self.assertEqual(self.gate.asks, [])

    def test_write_validates_complete_nested_schema_without_echoing_private_content(self):
        original = self.request()
        bad_arguments = [
            {key: value for key, value in original['arguments'].items() if key != 'recipient'},
            dict(original['arguments'], recipient='another@example.invalid'),
            dict(original['arguments'], body=42),
            dict(original['arguments'], body=''),
            dict(original['arguments'], body='private fixture should not appear ' * 100),
            dict(original['arguments'], options={'mode': 'html'}),
            dict(original['arguments'], options={'mode': 'plain', 'extra': True}),
            dict(original['arguments'], options={'mode': 'plain', 'labels': ['one', 'two', 'three']}),
            dict(original['arguments'], undeclared='never silently remove'),
        ]
        for args in bad_arguments:
            with self.subTest(args=args):
                error = self.assert_app_error('invalid_argument', lambda: self.operations.write(
                    self.request(arguments=args)))
                self.assertNotIn('private fixture should not appear', str(error))
                self.assertNotIn('another@example.invalid', str(error))
        self.assertEqual(self.bridge.calls, [])
        self.assertEqual(self.gate.asks, [])
        self.assertIsNone(self.row())

    def test_oversized_parameters_are_rejected_without_truncation(self):
        request = self.request(arguments={'body': 'x' * 160001})
        self.assert_app_error('invalid_argument', lambda: self.operations.write(request))
        self.assertEqual(self.bridge.calls, [])
        self.assertEqual(self.gate.asks, [])

    def test_invalid_operation_id_or_reason_never_reaches_review(self):
        for changes in ({'operation_id': 'short'}, {'operation_id': 'bad op id'},
                        {'operation_id': 'x' * 129}, {'operation_id': None},
                        {'reason': ''}, {'reason': '   '}, {'reason': None},
                        {'reason': 'x' * 4001}):
            with self.subTest(changes=changes):
                self.assert_app_error('invalid_argument',
                                      lambda: self.operations.write(self.request(**changes)))
        self.assertEqual(self.bridge.calls, [])
        self.assertEqual(self.gate.asks, [])

    def test_missing_schema_is_rejected_before_review_or_call(self):
        for schema in (None, [], 'not a schema'):
            with self.subTest(schema=schema):
                self.bridge.metadata[WRITE]['parameters'] = schema
                self.assert_app_error('invalid_schema', lambda: self.operations.write(self.request()))
        self.assertEqual(self.bridge.calls, [])
        self.assertEqual(self.gate.asks, [])

    def test_invalid_schema_is_reported_without_echoing_external_schema_contents(self):
        self.bridge.metadata[WRITE]['parameters'] = {
            'type': 'fixture-private-schema-value-that-must-not-be-echoed'}
        error = self.assert_app_error('invalid_schema', lambda: self.operations.write(self.request()))
        self.assertNotIn('fixture-private-schema-value', str(error))
        self.assertEqual(self.bridge.calls, [])
        self.assertEqual(self.gate.asks, [])

    def test_remote_schema_references_never_reach_reference_retrieval(self):
        for keyword, schema_version in (
                ('$ref', 'https://json-schema.org/draft/2020-12/schema'),
                ('$dynamicRef', 'https://json-schema.org/draft/2020-12/schema'),
                ('$recursiveRef', 'https://json-schema.org/draft/2019-09/schema')):
            with self.subTest(keyword=keyword):
                self.bridge.metadata[WRITE]['parameters'] = {
                    '$schema': schema_version, keyword: 'https://fixture.invalid/private-schema.json'}
                with patch('referencing.Registry.get_or_retrieve', side_effect=AssertionError('No reference retrieval permitted.')) as retrieve:
                    self.assert_app_error('invalid_schema', lambda: self.operations.write(self.request()))
                retrieve.assert_not_called()
        self.assertEqual(self.bridge.calls, [])
        self.assertEqual(self.gate.asks, [])

    def test_local_references_remain_usable(self):
        schema = self.bridge.metadata[WRITE]['parameters']
        body = schema['properties']['body']
        schema['properties']['body'] = {'$ref': '#/$defs/body'}
        schema['$defs'] = {'body': body}
        self.assertFalse(self.operations.write(self.request())['verified'])
        self.assertEqual(len(self.bridge.calls), 1)

    def test_parameter_validation_respects_the_declared_schema_draft(self):
        self.bridge.metadata[WRITE]['parameters'] = {
            '$schema': 'http://json-schema.org/draft-04/schema#', 'type': 'object',
            'properties': {'body': {'type': 'number', 'minimum': 1, 'exclusiveMinimum': True}},
            'required': ['body'], 'additionalProperties': False}
        self.assert_app_error('invalid_argument', lambda: self.operations.write(self.request(arguments={'body': 1})))
        self.assertFalse(self.operations.write(self.request(arguments={'body': 1.5}))['verified'])
        self.assertEqual(len(self.bridge.calls), 1)

    def test_exact_write_review_precedes_call_and_acknowledgement_is_never_verification(self):
        request = self.request()
        unchanged = copy.deepcopy(request)
        result = self.operations.write(request)
        action, context = self.gate.asks[0]
        self.assertEqual(action, {'app': 'Pico Connected Apps', 'kind': 'app_write',
                                  'tool': WRITE, 'arguments': request['arguments'],
                                  'accounts': [ACCOUNT], 'effects': 'write',
                                  'operation_id': request['operation_id'], 'reason': request['reason']})
        self.assertEqual(context, {'request_generation': 7})
        self.assertEqual(request, unchanged)
        self.assertEqual(self.bridge.calls[0]['name'], WRITE)
        self.assertEqual(self.bridge.calls[0]['arguments'], request['arguments'])
        self.assertEqual(self.bridge.calls[0]['operation_id'], request['operation_id'])
        self.assertEqual(self.bridge.calls[0]['expected_contract'], self.bridge.metadata[WRITE])
        sequence = [name for name, _ in self.events]
        self.assertLess(sequence.index('ask'), sequence.index('call'))
        self.assertEqual(sequence.count('describe'), 2)
        self.assertFalse(result['verified'])
        self.assertIn('Read the actual item', result['verification'])
        self.assertEqual(self.row()[1], 'submitted')
        self.assertFalse(json.loads(self.row()[2])['verified'])

    def test_destructive_facet_is_explicit_in_exact_review(self):
        result = self.operations.write(self.request(name=DELETE,
                                                   arguments={'message_id': 'fixture-delete-id'}))
        self.assertEqual(self.gate.asks[0][0]['effects'], 'destructive')
        self.assertFalse(result['verified'])

    def test_denial_or_modified_approval_never_calls_or_claims_operation(self):
        for decision, state in (('deny', 'denied'), ('changed', 'invalid_approval')):
            with self.subTest(decision=decision):
                self.gate.decision = decision
                self.assert_app_error(state, lambda: self.operations.write(self.request()))
                self.assertIsNone(self.row())
        self.assertEqual(self.bridge.calls, [])

    def test_task_cancelled_before_review_never_describes_or_calls(self):
        self.gate.cancel_on_check = 1
        with self.assertRaises(CancelledFixture):
            self.operations.write(self.request())
        self.assertEqual([event for event, _ in self.events], ['check'])
        self.assertEqual(self.bridge.calls, [])
        self.assertIsNone(self.row())

    def test_task_cancelled_during_review_never_calls(self):
        self.gate.on_ask = lambda _action, _context: setattr(self.gate, 'generation', 8)
        with self.assertRaises(CancelledFixture):
            self.operations.write(self.request())
        self.assertEqual(self.bridge.calls, [])
        self.assertIsNone(self.row())

    def test_final_cancellation_after_claim_releases_unsent_operation(self):
        self.gate.cancel_on_check = 4
        request = self.request()
        with self.assertRaises(CancelledFixture):
            self.operations.write(request)
        self.assertEqual(self.bridge.calls, [])
        self.assertIsNone(self.row())
        self.gate.cancel_on_check = None
        self.assertFalse(self.operations.write(request)['verified'])
        self.assertEqual(len(self.bridge.calls), 1)

    def test_account_switch_during_review_invalidates_the_exact_authorization(self):
        def change_account(_action, _context):
            self.bridge.metadata[WRITE]['accounts'] = [dict(ACCOUNT, alias='different-account')]
        self.gate.on_ask = change_account
        self.assert_app_error('account_changed', lambda: self.operations.write(self.request()))
        self.assertEqual(self.bridge.calls, [])
        self.assertIsNone(self.row())

    def test_schema_change_during_review_requires_fresh_review(self):
        def change_schema(_action, _context):
            self.bridge.metadata[WRITE]['parameters']['properties']['body']['maxLength'] = 999
        self.gate.on_ask = change_schema
        self.assert_app_error('account_changed', lambda: self.operations.write(self.request()))
        self.assertEqual(self.bridge.calls, [])
        self.assertIsNone(self.row())

    def test_facet_change_during_review_never_executes_using_old_classification(self):
        self.gate.on_ask = lambda _action, _context: self.bridge.metadata[WRITE].update(facet='read')
        self.assert_app_error('operation_mismatch', lambda: self.operations.write(self.request()))
        self.assertEqual(self.bridge.calls, [])

    def test_same_operation_after_restart_returns_saved_result_without_new_review_or_call(self):
        request = self.request()
        initial = self.operations.write(request)
        result = self.reopened().write(request)
        self.assertEqual(result, dict(initial, replayed=True))
        self.assertFalse(result['verified'])
        self.assertEqual(len(self.bridge.calls), 1)
        self.assertEqual(len(self.gate.asks), 1)

    def test_same_operation_with_other_content_or_account_is_conflict(self):
        request = self.request()
        self.operations.write(request)
        changed = copy.deepcopy(request)
        changed['arguments']['body'] = 'A different fixture message.'
        self.assert_app_error('operation_conflict', lambda: self.operations.write(changed))
        self.bridge.metadata[WRITE]['accounts'] = [dict(ACCOUNT, alias='other-fixture-account')]
        self.assert_app_error('operation_conflict', lambda: self.operations.write(request))
        self.assertEqual(len(self.bridge.calls), 1)
        self.assertEqual(len(self.gate.asks), 1)

    def test_explicitly_distinct_request_can_follow_a_successful_request(self):
        self.operations.write(self.request())
        changed = self.request(operation_id='fixture-op-0002')
        changed['arguments']['body'] = 'Another genuinely different fixture message.'
        self.assertFalse(self.operations.write(changed)['verified'])
        self.assertEqual(len(self.bridge.calls), 2)

    def test_error_response_is_unknown_not_verified_and_cannot_be_retried(self):
        request = self.request()
        self.bridge.result = {'error': {'code': 'timeout', 'message': 'Fixture acknowledgement lost.'},
                              'verified': True}
        self.assert_app_error('outcome_unknown', lambda: self.operations.write(request))
        self.assertEqual(self.row()[1], 'outcome_unknown')
        self.assertNotIn('verified', json.loads(self.row()[2]))
        self.bridge.result = {'result': {'id': 'would-be-a-duplicate'}, 'verified': True}
        self.assert_app_error('outcome_unknown', lambda: self.reopened().write(request))
        self.assert_app_error('outcome_unknown', lambda: self.reopened().write(
            self.request(operation_id='fixture-op-new-id')))
        self.assertEqual(len(self.bridge.calls), 1)

    def test_invalid_and_negative_execution_results_never_claim_verification(self):
        for index, response in enumerate((None, [], 'invalid', {'ok': False, 'verified': True})):
            with self.subTest(response=response):
                request = self.request(operation_id=f'fixture-negative-{index}')
                request['arguments']['body'] += str(index)
                self.bridge.result = response
                self.assert_app_error('outcome_unknown', lambda: self.operations.write(request))
                self.assertEqual(self.row(request['operation_id'])[1], 'outcome_unknown')
                self.assertNotIn('verified', json.loads(self.row(request['operation_id'])[2]))

    def test_exception_after_dispatch_is_persistent_unknown_for_same_or_different_id(self):
        request = self.request()
        self.bridge.failure = TimeoutError('Fixture timed out after possible remote submission.')
        with self.assertRaises(TimeoutError):
            self.operations.write(request)
        self.assertEqual(self.row()[1], 'outcome_unknown')
        self.bridge.failure = None
        self.assert_app_error('outcome_unknown', lambda: self.reopened().write(request))
        self.assert_app_error('outcome_unknown', lambda: self.reopened().write(
            self.request(operation_id='fixture-op-after-restart')))
        self.assertEqual(len(self.bridge.calls), 1)

    def test_in_flight_record_after_process_crash_is_never_reexecuted(self):
        request = self.request()
        self.operations.write(request)
        with closing(sqlite3.connect(self.data / 'connected-app-operations.sqlite')) as db:
            db.execute('UPDATE operations SET state=?,result=NULL WHERE id=?',
                       ('in_flight', request['operation_id']))
            db.commit()
        self.assert_app_error('outcome_unknown', lambda: self.reopened().write(request))
        self.assert_app_error('outcome_unknown', lambda: self.reopened().write(
            self.request(operation_id='fixture-op-after-crash')))
        self.assertEqual(len(self.bridge.calls), 1)

    def test_concurrent_same_intent_with_a_different_id_cannot_dispatch_twice(self):
        entered = threading.Event()
        release = threading.Event()
        result = []
        failure = []
        real_call = self.bridge.call

        def blocked_call(request):
            entered.set()
            if not release.wait(3):
                raise TimeoutError('Fixture did not release the in-flight call.')
            return real_call(request)

        def first_write():
            try:
                result.append(self.operations.write(self.request()))
            except BaseException as error:
                failure.append(error)

        self.bridge.call = blocked_call
        thread = threading.Thread(target=first_write)
        thread.start()
        try:
            self.assertTrue(entered.wait(3), 'Fixture first call did not become in flight.')
            self.assert_app_error('outcome_unknown', lambda: self.reopened().write(
                self.request(operation_id='fixture-concurrent-other')))
        finally:
            release.set()
            thread.join(3)
        self.assertFalse(thread.is_alive())
        self.assertEqual(failure, [])
        self.assertEqual(len(result), 1)
        self.assertFalse(result[0]['verified'])
        self.assertEqual(len(self.bridge.calls), 1)

    def test_journal_is_local_private_storage(self):
        self.operations.write(self.request())
        self.assertEqual(stat.S_IMODE(self.data.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.data / 'connected-app-operations.sqlite').stat().st_mode), 0o600)

    def test_connect_reviews_only_requested_platforms_before_starting_oauth(self):
        result = self.operations.connect({'connectors': ['gmail', 'figma']})
        action, context = self.gate.asks[0]
        self.assertEqual(action['kind'], 'connect_apps')
        self.assertEqual(action['connectors'], ['gmail', 'figma'])
        self.assertEqual(context, {'request_generation': 7})
        self.assertEqual(self.bridge.connections, [{'connectors': ['gmail', 'figma']}])
        self.assertEqual(result['apps'][0]['state'], 'connecting')
        self.assertEqual(self.bridge.calls, [])

    def test_connect_denial_or_cancellation_never_starts_authorization(self):
        self.gate.decision = 'deny'
        self.assert_app_error('denied', lambda: self.operations.connect({'connectors': ['gmail']}))
        self.gate.decision = 'approve'
        self.gate.on_ask = lambda _action, _context: setattr(self.gate, 'generation', 8)
        with self.assertRaises(CancelledFixture):
            self.operations.connect({'connectors': ['gmail']})
        self.assertEqual(self.bridge.connections, [])

    def test_connect_rejects_unsupported_empty_or_oversized_platform_sets(self):
        for values in (None, [], 'gmail', ['unsupported'], ['gmail'] * 5):
            with self.subTest(values=values):
                self.assert_app_error('invalid_argument',
                                      lambda: self.operations.connect({'connectors': values}))
        self.assertEqual(self.gate.asks, [])
        self.assertEqual(self.bridge.connections, [])


if __name__ == '__main__':
    unittest.main()
