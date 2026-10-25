import copy
import json
import os
from pathlib import Path
import signal
import shlex
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from zoom_connector import ZoomConnector, ZoomError, READ_TOOLS, WRITE_TOOLS, _result_error, _sanitize


class FakeHelper:
    def __init__(self):
        self.calls = []
        self.result = {'groups': []}
        self.schema = {'type': 'object', 'properties': {}, 'required': []}
        self.on_read = None

    def __call__(self, argv):
        self.calls.append(argv)
        args = argv[2:-1]
        if not args:
            return json.dumps([{'name': 'contact'}, {'name': 'meeting'}])
        if len(args) == 1:
            tools = READ_TOOLS.get(args[0], frozenset()) | WRITE_TOOLS.get(args[0], frozenset())
            return 'Zoom service tools:\n\n' + ''.join('  ' + name + '  Gateway metadata\n' for name in tools)
        if args[1] == 'schema':
            return 'Tool: ' + args[2] + '\nDescription: Read-only schema\n\nInput Schema:\n' + json.dumps(self.schema)
        if self.on_read:
            self.on_read()
        return json.dumps(self.result)


class ZoomConnectorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.data = Path(self.temp.name)
        self.binary = self.data / 'helper'
        self.binary.write_text('#!/bin/sh\nexit 0\n')
        self.binary.chmod(0o700)
        self.fake = FakeHelper()
        self.connector = ZoomConnector(self.data, runner=self.fake, helper=str(self.binary))

    def tearDown(self):
        self.temp.cleanup()

    def connect(self):
        self.assertEqual(self.connector.connect()['state'], 'connected')

    def read(self, tool='meeting_search', arguments=None, **extra):
        return self.connector.read({'service': 'meeting', 'tool': tool,
                                    'arguments': arguments or {}, **extra})

    def test_connect_verifies_real_read_and_stores_no_content_or_credentials(self):
        self.fake.result = {'groups': [{'name': 'Private group'}], 'access_token': 'secret'}
        result = self.connector.connect()
        self.assertTrue(result['enabled'])
        self.assertIn(result['verification'], ('last_successful_read', 'last_successful_request'))
        self.assertEqual(len(self.fake.calls), 4)
        self.assertEqual(self.fake.calls[-1][-3:], ['--args-json', '{}', '--json'])
        saved = self.connector.path.read_text()
        self.assertNotIn('Private group', saved)
        self.assertNotIn('secret', saved)
        self.assertEqual(self.connector.path.stat().st_mode & 0o777, 0o600)
        services = {item['id']: item for item in result['services']}
        self.assertTrue(services['contact']['verified'])
        self.assertFalse(services['meeting']['verified'])
        self.assertFalse(services['mail']['available'])

    def test_disconnected_metadata_and_cached_read_are_blocked(self):
        for method, args in ((self.connector.catalog, {}), (self.connector.schema, {'service': 'meeting', 'tool': 'meeting_search'}),
                             (self.connector.read, {'service': 'meeting', 'tool': 'meeting_search'})):
            with self.assertRaisesRegex(ZoomError, 'not connected'):
                method(args)
        self.assertFalse(self.fake.calls)
        self.connect()
        self.read()
        self.connector.disconnect()
        self.assertFalse(self.connector._read_cache)
        self.assertFalse(self.connector.status()['enabled'])
        with self.assertRaisesRegex(ZoomError, 'not connected'):
            self.read(output_offset=1)

    def test_disconnect_in_another_process_rechecks_flag_with_cached_schema(self):
        self.connect()
        self.read()
        count = len(self.fake.calls)
        ZoomConnector(self.data, helper=str(self.binary)).disconnect()
        with self.assertRaisesRegex(ZoomError, 'not connected'):
            self.read()
        self.assertEqual(len(self.fake.calls), count)

    def test_schema_before_invocation_and_argument_validation(self):
        self.connect()
        self.fake.schema = {'type': 'object', 'properties': {'page_size': {'type': 'integer', 'minimum': 1, 'maximum': 50}},
                            'required': ['page_size'], 'additionalProperties': False}
        for args in ({}, {'page_size': '1'}, {'page_size': 51}, {'page_size': True}, {'page_size': 1, 'unknown': 'x'}):
            with self.assertRaises(ZoomError):
                self.read(arguments=args)
        result = self.read(arguments={'page_size': 1})
        self.assertFalse(result['truncated'])
        meeting_calls = [argv for argv in self.fake.calls if 'meeting' in argv]
        self.assertEqual(meeting_calls[0][2:-1], ['meeting'])
        self.assertEqual(meeting_calls[1][2:-1], ['meeting', 'schema', 'meeting_search'])
        self.assertEqual(len(meeting_calls), 3)

    def test_arbitrary_tools_mutations_and_argv_injection_never_invoke(self):
        self.fake.schema = {'type': 'object', 'properties': {'query': {'type': 'string'}}}
        self.connect()
        count = len(self.fake.calls)
        for service, tool in [('meeting', 'meeting_delete'), ('docs', 'docs_file_create'),
                              ('team_chat', 'team_chat_msg_send'), ('recording', 'recording_transcript_generate'),
                              ('clips', 'clip_push'), ('meeting;echo', 'meeting_search'),
                              ('meeting', '--help'), ('unknown', 'get_token')]:
            with self.assertRaises(ZoomError):
                self.connector.read({'service': service, 'tool': tool, 'arguments': {}})
        self.assertEqual(len(self.fake.calls), count)
        payload = 'a; $(touch /tmp/not-executed) `echo bad`'
        self.read(arguments={'query': payload})
        self.assertEqual(json.loads(self.fake.calls[-1][-2])['query'], payload)

    def test_every_service_discovers_reads_and_writes_without_allowing_mutations_through_read(self):
        self.connect()
        for service in sorted(set(READ_TOOLS) | set(WRITE_TOOLS)):
            with self.subTest(service=service):
                result = self.connector.catalog({'service': service})
                self.assertEqual(set(result['read_tools']), READ_TOOLS.get(service, frozenset()))
                self.assertEqual(set(result['write_tools']), WRITE_TOOLS.get(service, frozenset()))
                self.assertTrue(set(result['read_tools']).isdisjoint(result['write_tools']))
                for tool in result['write_tools']:
                    before = len(self.fake.calls)
                    with self.assertRaises(ZoomError):
                        self.connector.read({'service': service, 'tool': tool, 'arguments': {}})
                    self.assertEqual(len(self.fake.calls), before,
                                     'A catalogued write must still fail before a read-path invocation')

    def test_captured_gateway_catalog_has_complete_and_disjoint_classification(self):
        # Independent counts from the read-only gateway inventory on 2026-10-24.
        # An intentional provider catalog update should refresh this baseline.
        expected = {'accelerator': 15, 'calendar': 9, 'clips': 21, 'contact': 3,
                    'docs': 38, 'docs_data_table': 8, 'mail': 12, 'meeting': 25,
                    'phone': 24, 'recording': 10, 'sheets': 10, 'tasks': 20,
                    'team_chat': 65, 'webinar': 20, 'whiteboard': 16, 'workspace': 26}
        self.assertEqual(set(READ_TOOLS) | set(WRITE_TOOLS), set(expected))
        for service, count in expected.items():
            with self.subTest(service=service):
                reads, writes = READ_TOOLS.get(service, frozenset()), WRITE_TOOLS.get(service, frozenset())
                self.assertTrue(reads.isdisjoint(writes))
                self.assertEqual(len(reads | writes), count)
        self.assertEqual(sum(expected.values()), 322)
        self.assertIn('team_chat_msg_send', WRITE_TOOLS['team_chat'])
        self.assertIn('mcp_send_message', WRITE_TOOLS['mail'])
        self.assertIn('sheets_edit_cells', WRITE_TOOLS['sheets'])
        self.assertIn('docs_data_table_schema', WRITE_TOOLS['docs_data_table'])

    def test_unauthenticated_or_permission_errors_are_not_empty_results(self):
        self.connect()
        for payload, expected in [({'status': False, 'errorCode': 2315, 'errorMessage': 'Access permission denied'}, 'permission_denied'),
                                  ({'code': 124, 'message': 'Invalid access token'}, 'needs_login'),
                                  ({'isError': True, 'content': [{'type': 'text', 'text': '401 Unauthorized'}]}, 'needs_login'),
                                  ({'content': [{'type': 'text', 'text': '{"success":false,"error":"403 forbidden"}'}]}, 'permission_denied')]:
            self.fake.result = payload
            with self.assertRaises(ZoomError) as caught:
                self.read()
            self.assertEqual(caught.exception.state, expected)
            self.assertEqual(self.connector.status()['state'], expected)
            self.assertFalse(self.connector._read_cache)
        self.fake.result = {'meetings': [], 'next_page_token': ''}
        self.assertEqual(self.read()['result']['meetings'], [])
        self.assertEqual(self.connector.status()['state'], 'connected')

    def test_failed_reconnect_persists_error_and_disconnect_clears_it(self):
        self.connect()
        self.fake.result = {'error': '401 Token expired'}
        self.assertEqual(self.connector.connect()['state'], 'needs_login')
        self.assertEqual(ZoomConnector(self.data, helper=str(self.binary)).status()['state'], 'needs_login')
        self.assertEqual(self.connector.disconnect()['state'], 'disconnected')

    def test_response_chunks_are_exact_bounded_and_do_not_refetch(self):
        self.connect()
        self.fake.result = {'text': '中文 text ' * 12000, 'next_page_token': 'server-next', 'total': 21,
                            'content': [{'type': 'text', 'text': '{"refreshToken":"secret","body":"hello"}'}]}
        first = self.read()
        self.assertTrue(first['truncated'])
        self.assertLessEqual(len(first['content_excerpt']), 24000)
        self.assertEqual(first['pagination']['next_page_token'], 'server-next')
        calls = len(self.fake.calls)
        chunks = [first['content_excerpt']]
        next_offset = first['next_output_offset']
        while next_offset is not None:
            chunk = self.read(output_offset=next_offset)
            chunks.append(chunk['content_excerpt'])
            next_offset = chunk['next_output_offset']
        self.assertEqual(len(self.fake.calls), calls)
        result = json.loads(''.join(chunks))
        self.assertEqual(result['text'], self.fake.result['text'])
        self.assertNotIn('secret', ''.join(chunks))
        with self.assertRaises(ZoomError):
            self.read(arguments={'query': 'different'}, output_offset=1)
        for offset in (-1, True, '1', first['total_characters']):
            with self.assertRaises(ZoomError):
                self.read(output_offset=offset)

    def test_result_cache_is_capped_and_connection_generation_invalidates(self):
        self.fake.schema = {'type': 'object', 'properties': {'query': {'type': 'string'}}}
        self.connect()
        self.fake.result = {'text': 'x' * 30000}
        for index in range(5):
            self.read(arguments={'query': str(index)})
        self.assertEqual(len(self.connector._read_cache), 4)
        with self.assertRaises(ZoomError):
            self.read(arguments={'query': '0'}, output_offset=1)
        self.connect()
        with self.assertRaises(ZoomError):
            self.read(arguments={'query': '4'}, output_offset=1)

    def test_select_guard_excludes_sql_writes_and_chained_statements(self):
        self.fake.schema = {'type': 'object', 'properties': {'type': {'type': 'string'}, 'sql': {'type': 'string'}}}
        self.connect()
        args = {'service': 'docs_data_table', 'tool': 'docs_data_table_fetch', 'arguments': {'type': 'row'}}
        for sql in ('DELETE FROM data', 'SELECT * FROM data; DROP TABLE data', 'SELECT load_extension("bad")',
                    'SELECT * FROM data -- comment', 'SELECT * /* hidden */ FROM data'):
            args['arguments']['sql'] = sql
            with self.assertRaises(ZoomError):
                self.connector.read(args)
        args['arguments']['sql'] = 'SELECT * FROM data LIMIT 10'
        self.connector.read(args)

    def test_secret_redaction_nested_mcp_json_but_preserves_pagination(self):
        raw = {'accessToken': 'one', 'nested': {'client_secret': 'two'},
               'next_page_token': 'cursor', 'text': 'Bearer asecret and https://example.com/?api_key=secret',
               'content': [{'text': '{"refresh_token":"three","data":[{"password":"four"}]}'}]}
        safe = json.dumps(_sanitize(raw))
        for secret in ('one', 'two', 'three', 'four', 'asecret', '=secret'):
            self.assertNotIn(secret, safe)
        self.assertIn('cursor', safe)

    def test_session_metadata_schema_only_corrects_its_documented_single_or_batch_identifier(self):
        self.connect()
        raw = {'type': 'object', 'properties': {
            'chat_session_id': {'type': 'object', 'properties': {},
                'description': 'Accepts either a single string or an array of up to 10 strings.'},
            'unrelated_object': {'type': 'object', 'properties': {},
                'description': 'Accepts either a single string or an array of up to 10 strings.'}},
            'required': ['chat_session_id']}
        self.fake.schema = copy.deepcopy(raw)
        metadata = self.connector.schema({'service': 'team_chat', 'tool': 'team_chat_session_metadata_fetch'})
        self.assertEqual(metadata['raw_input_schema'], raw)
        self.assertIn('compatibility_note', metadata)
        self.assertIn('oneOf', metadata['inputSchema']['properties']['chat_session_id'])
        self.assertEqual(metadata['inputSchema']['properties']['unrelated_object']['type'], 'object')
        for value in ('synthetic-session', ['synthetic-session'], ['synthetic-' + str(index) for index in range(10)]):
            with self.subTest(value=value):
                self.connector.read({'service': 'team_chat', 'tool': 'team_chat_session_metadata_fetch',
                                     'arguments': {'chat_session_id': value}})
                self.assertEqual(json.loads(self.fake.calls[-1][-2]), {'chat_session_id': value})
        self.assertEqual(self.fake.schema, raw)

    def test_session_metadata_compatibility_rejects_empty_large_mixed_and_other_object_values(self):
        self.connect()
        self.fake.schema = {'type': 'object', 'properties': {
            'chat_session_id': {'type': 'object', 'properties': {},
                'description': 'Accepts either a single string or an array of up to 10 strings.'},
            'unrelated_object': {'type': 'object', 'properties': {}}}, 'required': ['chat_session_id']}
        self.connector.schema({'service': 'team_chat', 'tool': 'team_chat_session_metadata_fetch'})
        for value in ('', [], [''] , ['one', None], {}, ['session-' + str(index) for index in range(11)]):
            with self.subTest(value=value):
                before = len(self.fake.calls)
                with self.assertRaises(ZoomError):
                    self.connector.read({'service': 'team_chat', 'tool': 'team_chat_session_metadata_fetch',
                                         'arguments': {'chat_session_id': value}})
                self.assertEqual(len(self.fake.calls), before)
        with self.assertRaises(ZoomError):
            self.connector.read({'service': 'team_chat', 'tool': 'team_chat_session_metadata_fetch',
                                 'arguments': {'chat_session_id': 'session', 'unrelated_object': 'not an object'}})
        other = ZoomConnector(self.data, runner=self.fake, helper=str(self.binary))
        with self.assertRaises(ZoomError):
            other.read({'service': 'team_chat', 'tool': 'team_chat_msg_get_by_id',
                        'arguments': {'chat_session_id': 'the same field in another tool stays object'}})

    def test_session_metadata_compatibility_requires_the_exact_documented_empty_object(self):
        self.connect()
        for field in ({'type': 'object', 'properties': {}, 'description': 'A structured session identifier.'},
                      {'type': 'object', 'properties': {'id': {'type': 'string'}},
                       'description': 'Accepts either a single string or an array of up to 10 strings.'}):
            with self.subTest(field=field):
                self.fake.schema = {'type': 'object', 'properties': {'chat_session_id': field}, 'required': ['chat_session_id']}
                zoom = ZoomConnector(self.data, runner=self.fake, helper=str(self.binary))
                metadata = zoom.schema({'service': 'team_chat', 'tool': 'team_chat_session_metadata_fetch'})
                self.assertNotIn('compatibility_note', metadata)
                with self.assertRaises(ZoomError):
                    zoom.read({'service': 'team_chat', 'tool': 'team_chat_session_metadata_fetch',
                               'arguments': {'chat_session_id': 'not an object'}})

    def test_only_exact_gateway_no_text_failure_gets_the_uncertain_empty_response_classification(self):
        for stderr, stdout, expected in (
                ('Error: Gateway returned no text content [trackingId=ZOAP-fixture_1]', '', 'empty_response'),
                ('Error: Gateway returned no text content [trackingId=ZOAP-fixture_1] extra diagnostic', '', 'unavailable'),
                ('Gateway returned no text content without a tracking identity', '', 'unavailable'),
                ('Error: Gateway returned no text content [trackingId=ZOAP-fixture_1]', '{}', 'unavailable'),
                ('403 permission denied', '', 'permission_denied')):
            with self.subTest(stderr=stderr, stdout=stdout):
                self.binary.write_text('#!/bin/sh\nprintf %s ' + shlex.quote(stdout) + '\nprintf %s ' + shlex.quote(stderr) + ' >&2\nexit 1\n')
                zoom = ZoomConnector(self.data, helper=str(self.binary))
                with self.assertRaises(ZoomError) as caught:
                    zoom._command([])
                self.assertEqual(caught.exception.state, expected)

    def test_process_timeout_and_output_limit_stop_the_helper(self):
        self.binary.write_text('#!/bin/sh\nprintf "%s" "$$" > "$PICO_ZOOM_TEST_PID"\nexec /bin/sleep 20\n')
        connector = ZoomConnector(self.data, helper=str(self.binary))
        connector.COMMAND_TIMEOUT = 0.5
        start = time.monotonic()
        pid_path = self.data / 'helper-pid'
        with patch.dict(os.environ, PICO_ZOOM_TEST_PID=str(pid_path)):
            with self.assertRaises(ZoomError) as caught:
                connector._command([])
        self.assertEqual(caught.exception.state, 'timeout')
        self.assertLess(time.monotonic() - start, 3)
        if pid_path.exists():
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pid_path.read_text()), 0)
        output_binary = self.data / 'output-helper'
        output_binary.write_text('#!/bin/sh\nprintf "%10000s" x\n')
        output_binary.chmod(0o700)
        connector.helper = str(output_binary)
        connector.COMMAND_TIMEOUT = 10
        connector.OUTPUT_LIMIT = 100
        with self.assertRaises(ZoomError) as caught:
            connector._command([])
        self.assertEqual(caught.exception.state, 'response_too_large')


if __name__ == '__main__':
    unittest.main()
