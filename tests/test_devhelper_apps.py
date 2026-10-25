import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from devhelper_apps import DevHelperApps, DevHelperAppError, READ_TOOLS, WRITE_TOOLS, operation_kind, _failure, _MCPCall


PROFILE = {'type': 'object', 'properties': {}, 'additionalProperties': False}
COMMENT = {'type': 'object', 'properties': {'file_key': {'type': 'string'}, 'message': {'type': 'string'}},
           'required': ['file_key', 'message'], 'additionalProperties': False}


class Fixture:
    def __init__(self):
        self.tools = {
            'figma': {'FIGMA_GET_CURRENT_USER': 'Get profile information.',
                      'FIGMA_ADD_A_COMMENT_TO_A_FILE': 'Add a review comment.',
                      'FIGMA_DELETE_EVERYTHING': 'New unclassified tool.'},
            'google_mail': {'GMAIL_GET_PROFILE': 'Get the connected mailbox identity.',
                            'GMAIL_SEND_EMAIL': 'Send an email.', 'test': 'test'},
        }
        self.schemas = {'FIGMA_GET_CURRENT_USER': PROFILE, 'FIGMA_ADD_A_COMMENT_TO_A_FILE': COMMENT,
                        'FIGMA_DELETE_EVERYTHING': PROFILE, 'GMAIL_GET_PROFILE': PROFILE,
                        'GMAIL_SEND_EMAIL': COMMENT, 'test': PROFILE}
        self.calls, self.commands = [], []
        self.account = 'fixture@example.test'
        self.mail_enabled = False

    def runner(self, command):
        self.commands.append(command)
        app = command[2]
        if command[3] == 'schema':
            return 'Tool: ' + command[4] + '\nInput Schema:\n' + json.dumps(self.schemas[command[4]])
        tools = self.tools[app]
        return f'Fixture — {len(tools)} tools:\n\n' + '\n'.join(f'  {tool:<40}  {desc}' for tool, desc in tools.items())

    def caller(self, app, tool, arguments, schema):
        self.calls.append((app, tool, arguments, schema))
        if tool == 'FIGMA_GET_CURRENT_USER':
            return {'structuredContent': {'email': self.account, 'id': 'fixture-account'}}
        if tool == 'GMAIL_GET_PROFILE':
            if not self.mail_enabled:
                raise _failure('Mail service not enabled access_token=hidden-fixture')
            return {'structuredContent': {'emailAddress': self.account}}
        return {'content': [{'type': 'text', 'text': 'accepted'}], 'access_token': 'hidden-fixture'}


class DevHelperAppsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.fixture = Fixture()
        self.bridge = DevHelperApps(self.directory.name, helper=sys.executable,
                                   runner=self.fixture.runner, caller=self.fixture.caller)

    def tearDown(self):
        self.directory.cleanup()

    def test_figma_identity_is_actually_checked(self):
        result = self.bridge.status('figma')
        self.assertTrue(result['connected'])
        self.assertEqual(result['accounts'][0]['label'], self.fixture.account)
        self.assertEqual(self.fixture.calls[0][1], 'FIGMA_GET_CURRENT_USER')
        self.assertTrue(any('schema' in command for command in self.fixture.commands))

    def test_gmail_mail_service_not_enabled_never_connected(self):
        result = self.bridge.status('gmail')
        self.assertFalse(result['connected'])
        self.assertEqual(result['state'], 'needs_authorization')
        self.assertNotIn('hidden-fixture', json.dumps(result))

    def test_gmail_enabled_identity(self):
        self.fixture.mail_enabled = True
        self.assertTrue(self.bridge.status('gmail')['connected'])

    def test_connector_mcp_nested_gateway_envelope_is_unwrapped(self):
        inner = {'jsonrpc': '2.0', 'id': 'gateway',
                 'result': {'structuredContent': {'email': self.fixture.account}, 'isError': False}}
        outer = {'content': [{'type': 'text', 'text': json.dumps(inner)}]}
        self.assertEqual(self.bridge._identity(outer)['email'], self.fixture.account)

    def test_catalogue_discovery_does_not_prove_identity(self):
        result = self.bridge.search('gmail', 'send email')
        self.assertIn('connectors__gmail__GMAIL_SEND_EMAIL', result['tools'])
        self.assertNotIn('connected', result)
        self.assertEqual(self.fixture.calls, [])

    def test_exact_classification_including_unknown(self):
        self.assertEqual(len(READ_TOOLS['gmail']), 25)
        self.assertEqual(len(WRITE_TOOLS['gmail']), 4)
        self.assertEqual(len(READ_TOOLS['figma']), 18)
        self.assertEqual(len(WRITE_TOOLS['figma']), 1)
        self.assertEqual(operation_kind('gmail', 'test'), 'unclassified')
        self.assertEqual(operation_kind('figma', 'FIGMA_DELETE_EVERYTHING'), 'unclassified')
        self.assertEqual(operation_kind('figma', 'FIGMA_ADD_A_COMMENT_TO_A_FILE'), 'write')

    def test_describe_keeps_exact_json_schema_and_verified_account(self):
        name = 'connectors__figma__FIGMA_ADD_A_COMMENT_TO_A_FILE'
        result = self.bridge.describe([name])['tools'][name]
        self.assertEqual(result['parameters'], COMMENT)
        self.assertEqual(result['facet'], 'write')
        self.assertEqual(result['accounts'][0]['label'], self.fixture.account)
        self.assertEqual(result['provider'], 'devhelper')

    def test_approved_write_uses_caller_not_process_arguments(self):
        name = 'connectors__figma__FIGMA_ADD_A_COMMENT_TO_A_FILE'
        contract = self.bridge.describe([name])['tools'][name]
        arguments = {'file_key': 'fixture-file', 'message': 'Private body $(no-command)'}
        result = self.bridge.call({'name': name, 'arguments': arguments,
                                   'operation_id': 'fixture-operation-1', 'expected_contract': contract})
        self.assertTrue(result['submitted'])
        self.assertFalse(result['verified'])
        self.assertEqual(result['result']['access_token'], '[redacted]')
        self.assertEqual(self.fixture.calls[-1][2], arguments)
        self.assertNotIn('Private body', json.dumps(self.fixture.commands))

    def test_missing_stable_write_operation_id_stops_dispatch(self):
        with self.assertRaises(DevHelperAppError) as error:
            self.bridge.call({'name': 'connectors__figma__FIGMA_ADD_A_COMMENT_TO_A_FILE',
                              'arguments': {'file_key': 'fixture', 'message': 'fixture'}})
        self.assertEqual(error.exception.code, 'invalid_argument')
        self.assertFalse(any(call[1] == 'FIGMA_ADD_A_COMMENT_TO_A_FILE' for call in self.fixture.calls))

    def test_schema_validation_rejects_wrong_types_and_unknown_fields(self):
        for arguments in ({'file_key': 1, 'message': 'fixture'}, {'file_key': 'fixture'},
                          {'file_key': 'fixture', 'message': 'fixture', 'unexpected': True}):
            with self.assertRaises(DevHelperAppError):
                self.bridge.call({'name': 'connectors__figma__FIGMA_ADD_A_COMMENT_TO_A_FILE',
                                  'arguments': arguments, 'operation_id': 'fixture-operation-1'})
        self.assertEqual(self.fixture.calls, [])

    def test_unknown_tool_stops_even_if_catalogue_and_schema_include_it(self):
        with self.assertRaises(DevHelperAppError) as error:
            self.bridge.call({'name': 'connectors__figma__FIGMA_DELETE_EVERYTHING', 'arguments': {}})
        self.assertEqual(error.exception.code, 'unclassified')
        self.assertEqual(self.fixture.calls, [])

    def test_account_switch_invalidates_contract_before_write(self):
        name = 'connectors__figma__FIGMA_ADD_A_COMMENT_TO_A_FILE'
        contract = self.bridge.describe([name])['tools'][name]
        self.fixture.account = 'different@example.test'
        with self.assertRaises(DevHelperAppError) as error:
            self.bridge.call({'name': name, 'arguments': {'file_key': 'fixture', 'message': 'fixture'},
                              'operation_id': 'fixture-operation-1', 'expected_contract': contract})
        self.assertEqual(error.exception.code, 'account_changed')
        self.assertFalse(any(call[1] == 'FIGMA_ADD_A_COMMENT_TO_A_FILE' for call in self.fixture.calls))

    def test_schema_change_invalidates_contract_before_write(self):
        name = 'connectors__figma__FIGMA_ADD_A_COMMENT_TO_A_FILE'
        contract = self.bridge.describe([name])['tools'][name]
        self.fixture.schemas['FIGMA_ADD_A_COMMENT_TO_A_FILE'] = dict(COMMENT, description='Changed')
        with self.assertRaises(DevHelperAppError) as error:
            self.bridge.call({'name': name, 'arguments': {'file_key': 'fixture', 'message': 'fixture'},
                              'operation_id': 'fixture-operation-1', 'expected_contract': contract})
        self.assertEqual(error.exception.code, 'schema_changed')

    def test_names_cannot_escape_allowed_connector(self):
        for name in ('connectors__notion__read', 'connectors__figma__; rm -rf', 'FIGMA_GET_CURRENT_USER'):
            with self.assertRaises(DevHelperAppError):
                self.bridge.describe([name])
        with self.assertRaises(DevHelperAppError):
            self.bridge.status('twitter')

    def test_errors_never_echo_diagnostics(self):
        error = _failure('Error token=secret https://example.test/authorize?code=secret')
        self.assertNotIn('secret', error.message)
        self.assertNotIn('https://', error.message)

    def test_mcp_contract_change_stops_tools_call(self):
        # Exercise the real session method with a deterministic wire transport.
        session = object.__new__(_MCPCall)
        session.dispatched = False
        sent = []
        session.send = sent.append
        replies = iter(({}, {'tools': [{'name': 'FIGMA_ADD_A_COMMENT_TO_A_FILE', 'inputSchema': PROFILE}]}))
        session.receive = lambda identity: next(replies)
        with self.assertRaises(DevHelperAppError) as error:
            session.call('FIGMA_ADD_A_COMMENT_TO_A_FILE', {}, COMMENT)
        self.assertEqual(error.exception.code, 'schema_changed')
        self.assertFalse(session.dispatched)
        self.assertFalse(any(item.get('method') == 'tools/call' for item in sent))


if __name__ == '__main__':
    unittest.main()
