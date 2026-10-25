import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from connected_apps import ConnectedApps, ConnectedAppError, _dispatch, _connect_url, _safe_error


class HermesFake:
    def __init__(self, identity=True):
        self.signed_in = identity
        self.provisions = self.connections = self.executions = 0
        self.rows = [
            {'connector': 'gmail', 'connected': True, 'accounts': [{'alias': 'home', 'label': 'Me', 'active': True}]},
            {'connector': 'x', 'connected': False},
            {'connector': 'notion', 'connected': False},
            {'connector': 'figma', 'connected': False},
            {'connector': 'slack', 'connected': True},
        ]
        self.schema = {'type': 'object', 'properties': {'text': {'type': 'string', 'minLength': 2}},
                       'required': ['text'], 'additionalProperties': False}
        self.facet = 'write'
        self.file_input = False
        self.reply = {'response': {'id': 'created'}, 'account': 'home'}
        self.description_calls = 0

    def identity(self): return self.signed_in
    def provision(self):
        self.provisions += 1
        self.signed_in = True
    def status(self): return {'connectors': self.rows}
    def connect(self, slugs):
        self.connections += 1
        self.connected_slugs = slugs
        return {'targets': [{'name': slug, 'state': 'initiated',
                             'connect_url': 'https://portal.nousresearch.com/connect?code=do-not-log'} for slug in slugs]}
    def search(self, query):
        return {'schemas': {
            'GMAIL_SEND': {'connector': 'gmail', 'description': 'Send mail'},
            'X_POST': {'connector': 'x', 'description': 'Publish a post'},
            'SLACK_SEND': {'connector': 'slack', 'description': 'Send in Slack'},
        }}
    def describe(self, names):
        self.description_calls += 1
        return {'tools': {name: {'description': 'Create a result', 'parameters': self.schema} for name in names}}
    def facets(self, slug): return {f'{slug.upper()}_SEND': self.facet, f'{slug.upper()}_POST': self.facet}
    def raw_schema(self, name):
        return {'type': 'object', 'properties': {'text': {'file_uploadable': True}}} if self.file_input else self.schema
    def call(self, name, arguments, operation_id=None):
        self.executions += 1
        self.called = (name, arguments, operation_id)
        return self.reply


class DevHelperFake:
    def __init__(self):
        self.status_calls, self.execute_calls = [], []
        self.connected = True
        self.account = 'personal@example.com'
        self.changed_account = None

    def status(self, app):
        self.status_calls.append(app)
        return {'id': app, 'name': app, 'connected': self.connected,
                'state': 'connected' if self.connected else 'needs_authorization',
                'accounts': [{'label': self.account, 'active': True}], 'provider': 'devhelper'}

    def search(self, app, query):
        return {'tools': {f'connectors__{app}__LIST': {'description': 'List items'}}}

    def describe(self, names):
        return {'tools': {name: {'description': 'List items', 'parameters': {'type': 'object', 'additionalProperties': False},
                                'facet': 'read', 'accounts': [{'label': self.changed_account or self.account, 'active': True}],
                                'provider': 'devhelper'} for name in names}}

    def call(self, args):
        self.execute_calls.append(args)
        return {'result': {'items': []}, 'account': self.account, 'submitted': False, 'verified': False,
                'provider': 'devhelper'}


class ConnectedAppsTests(unittest.TestCase):
    def test_status_without_identity_does_not_provision_or_fetch(self):
        fake = HermesFake(False)
        fake.status = lambda: self.fail('status must not call a remote service without an identity')
        result = _dispatch('status', {}, fake)
        self.assertEqual(result['identity_state'], 'not_connected')
        self.assertEqual([r['state'] for r in result['apps']], ['disconnected'] * 4)
        self.assertEqual(fake.provisions, 0)

    def test_search_without_identity_does_not_provision(self):
        fake = HermesFake(False)
        with self.assertRaises(ConnectedAppError) as raised:
            _dispatch('search', {'query': 'read mail'}, fake)
        self.assertEqual(raised.exception.code, 'not_connected')
        self.assertEqual(fake.provisions, 0)

    def test_connect_explicitly_provisions_and_uses_real_x_slug(self):
        fake = HermesFake(False)
        result = _dispatch('connect', {'connectors': ['twitter', 'gmail']}, fake)
        self.assertEqual(fake.provisions, 1)
        self.assertEqual(fake.connected_slugs, ['x'])
        self.assertEqual(result['apps'][0]['state'], 'connecting')
        self.assertFalse(result['apps'][0]['connected'])
        self.assertIn('connect_url', result['apps'][0])
        self.assertTrue(result['apps'][1]['connected'])

    def test_connect_requires_explicit_apps_and_refuses_unknown_platforms(self):
        fake = HermesFake(False)
        for args in ({}, {'connectors': ['slack']}, {'connectors': ['gmail', 'notion', 'figma', 'twitter', 'x']}):
            with self.assertRaises(ConnectedAppError):
                _dispatch('connect', args, fake)
        self.assertEqual(fake.provisions, 0)

    def test_missing_platform_is_unavailable_instead_of_false_disconnected(self):
        fake = HermesFake()
        fake.rows = fake.rows[:1]
        result = _dispatch('status', {'connectors': ['figma', 'gmail']}, fake)
        self.assertEqual(result['apps'][0]['state'], 'unavailable')
        self.assertEqual(result['apps'][1]['accounts'][0]['label'], 'Me')

    def test_no_second_authorization_for_connected_app(self):
        fake = HermesFake()
        result = _dispatch('connect', {'connectors': ['gmail']}, fake)
        self.assertEqual(fake.connections, 0)
        self.assertTrue(result['apps'][0]['connected'])

    def test_search_uses_only_actual_allowed_platforms_and_filter(self):
        result = _dispatch('search', {'query': 'send', 'connectors': ['gmail']}, HermesFake())
        self.assertEqual(set(result['tools']), {'connectors__gmail__SEND'})
        result = _dispatch('search', {'query': 'send'}, HermesFake())
        self.assertEqual(set(result['tools']), {'connectors__gmail__SEND', 'connectors__x__POST'})

    def test_exact_real_catalogue_tool_is_found_when_semantic_search_omits_it(self):
        fake = HermesFake()
        fake.catalogue = lambda slug: {'NOTION_GET_ABOUT_ME': {'description': 'Retrieve the current bot user.', 'facet': 'read'}} if slug == 'notion' else {}
        result = _dispatch('search', {'query': 'NOTION_GET_ABOUT_ME', 'connectors': ['notion']}, fake)
        self.assertIn('connectors__notion__GET_ABOUT_ME', result['tools'])
        self.assertEqual(result['tools']['connectors__notion__GET_ABOUT_ME']['facet'], 'read')
        self.assertEqual(next(iter(result['tools'])), 'connectors__notion__GET_ABOUT_ME')

    def test_catalogue_description_search_supplements_remote_omission_without_content_reads(self):
        fake = HermesFake()
        requested = []
        def catalogue(slug):
            requested.append(slug)
            return {'NOTION_GET_ABOUT_ME': {'description': 'Retrieve the current bot user.', 'facet': 'read'},
                    'NOTION_CREATE_PAGE': {'description': 'Create a page.', 'facet': 'write'}}
        fake.catalogue = catalogue
        fake.call = lambda *args: self.fail('Tool discovery must never fetch account content')
        result = _dispatch('search', {'query': 'current bot user', 'connectors': ['notion']}, fake)
        self.assertEqual(requested, ['notion'])
        self.assertEqual(set(result['tools']), {'connectors__notion__GET_ABOUT_ME'})

    def test_metadata_search_is_bounded_and_exact_tool_ranks_first(self):
        fake = HermesFake()
        fake.catalogue = lambda slug: {f'NOTION_ACTION_{i}': {'description': 'Edit page', 'facet': 'write'} for i in range(50)}
        result = _dispatch('search', {'query': 'Edit page NOTION_ACTION_49', 'connectors': ['notion']}, fake)
        self.assertEqual(len(result['tools']), 30)
        self.assertEqual(next(iter(result['tools'])), 'connectors__notion__ACTION_49')

    def test_describe_exposes_authoritative_facet_schema_and_accounts(self):
        result = _dispatch('describe', {'names': ['connectors__gmail__SEND']}, HermesFake())
        tool = result['tools']['connectors__gmail__SEND']
        self.assertEqual(tool['facet'], 'write')
        self.assertEqual(tool['parameters']['required'], ['text'])
        self.assertEqual(tool['accounts'][0]['alias'], 'home')

    def test_unknown_facet_never_becomes_read(self):
        fake = HermesFake()
        fake.facet = 'a-new-untrusted-facet'
        result = _dispatch('describe', {'names': ['connectors__gmail__SEND']}, fake)
        self.assertEqual(result['tools']['connectors__gmail__SEND']['facet'], 'unclassified')

    def test_describe_denies_tools_of_other_apps(self):
        with self.assertRaises(ConnectedAppError) as raised:
            _dispatch('describe', {'names': ['connectors__slack__SEND']}, HermesFake())
        self.assertEqual(raised.exception.code, 'unsupported_app')

    def test_call_reloads_schema_and_strictly_rejects_invalid_arguments(self):
        fake = HermesFake()
        for args in ({}, {'text': 7}, {'text': 'x'}, {'text': 'okay', 'extra': 'bad'}):
            with self.assertRaises(ConnectedAppError):
                _dispatch('call', {'name': 'connectors__gmail__SEND', 'arguments': args}, fake)
        self.assertEqual(fake.executions, 0)
        self.assertEqual(fake.description_calls, 4)

    def test_call_returns_account_and_never_claims_readback(self):
        fake = HermesFake()
        result = _dispatch('call', {'name': 'connectors__gmail__SEND', 'arguments': {'text': 'okay'},
                                    'operation_id': 'stable-operation'}, fake)
        self.assertEqual(result['account'], 'home')
        self.assertTrue(result['submitted'])
        self.assertFalse(result['verified'])
        self.assertEqual(fake.called[2], 'stable-operation')

    def test_upload_schema_blocks_execution_even_after_facade_transform(self):
        fake = HermesFake()
        fake.file_input = True
        with self.assertRaises(ConnectedAppError) as raised:
            _dispatch('call', {'name': 'connectors__gmail__SEND', 'arguments': {'text': '/Users/me/.secret'}}, fake)
        self.assertEqual(raised.exception.code, 'file_input_unsupported')
        self.assertEqual(fake.executions, 0)

    def test_optional_upload_does_not_block_ordinary_mail(self):
        fake = HermesFake()
        fake.raw_schema = lambda name: {'type': 'object', 'properties': {
            'text': {'type': 'string'}, 'attachment': {'file_uploadable': True}}}
        result = _dispatch('call', {'name': 'connectors__gmail__SEND', 'arguments': {'text': 'hello'}}, fake)
        self.assertTrue(result['submitted'])

    def test_nested_reference_upload_is_refused(self):
        fake = HermesFake()
        fake.schema = {'type': 'object', 'properties': {'files': {'type': 'array', 'items': {'type': 'string'}}}}
        fake.raw_schema = lambda name: {'type': 'object', 'properties': {'files': {'type': 'array', 'items': {'$ref': '#/$defs/upload'}}},
                                       '$defs': {'upload': {'file_uploadable': True}}}
        with self.assertRaises(ConnectedAppError) as raised:
            _dispatch('call', {'name': 'connectors__gmail__SEND', 'arguments': {'files': ['/Users/me/.secret']}}, fake)
        self.assertEqual(raised.exception.code, 'file_input_unsupported')
        self.assertEqual(fake.executions, 0)

    def test_external_schema_reference_is_not_fetched(self):
        fake = HermesFake()
        fake.raw_schema = lambda name: {'$ref': 'https://example.com/secret-schema'}
        with self.assertRaises(ConnectedAppError) as raised:
            _dispatch('call', {'name': 'connectors__gmail__SEND', 'arguments': {'text': 'okay'}}, fake)
        self.assertEqual(raised.exception.code, 'unsupported_schema')
        self.assertEqual(fake.executions, 0)

    def test_provider_timeout_is_uncertain_and_not_retried(self):
        fake = HermesFake()
        fake.reply = {'error': {'code': 'PROVIDER_TIMEOUT', 'message': 'Slow upstream https://example.com/?token=secret'}}
        result = _dispatch('call', {'name': 'connectors__gmail__SEND', 'arguments': {'text': 'okay'}}, fake)
        self.assertTrue(result['outcome_unknown'])
        self.assertNotIn('token=secret', json.dumps(result))
        self.assertEqual(fake.executions, 1)

    def test_predispatch_failure_is_not_success_or_unknown(self):
        fake = HermesFake()
        fake.reply = {'error': {'code': 'CONNECTION_REQUIRED', 'message': 'Connect first',
                                'connect_url': 'https://example.com/?code=secret'}}
        result = _dispatch('call', {'name': 'connectors__gmail__SEND', 'arguments': {'text': 'okay'}}, fake)
        self.assertNotIn('submitted', result)
        self.assertNotIn('outcome_unknown', result)
        self.assertNotIn('connect_url', json.dumps(result))

    def test_child_timeout_marks_write_unknown_without_retry(self):
        calls = []
        def runner(payload, timeout):
            calls.append(payload)
            raise subprocess.TimeoutExpired('bridge', timeout)
        result = ConnectedApps('/tmp/pico-app-tests', runner=runner).call({'name': 'anything', 'arguments': {}})
        self.assertTrue(result['outcome_unknown'])
        self.assertEqual(len(calls), 1)

    def test_child_receives_only_system_env_and_own_hermes_home(self):
        observed = {}
        def run(command, **kwargs):
            observed.update(kwargs)
            kwargs['stdout'].write(b'{"apps":[]}')
            return subprocess.CompletedProcess(command, 0)
        with patch.dict('os.environ', {'TOOL_GATEWAY_USER_TOKEN': 'not-ours', 'OPENAI_API_KEY': 'not-ours',
                                       'HERMES_HOME': '/some/other/client', 'HERMES_OAUTH_TRACE': '1'}), \
             patch('connected_apps.subprocess.run', side_effect=run):
            result = ConnectedApps('/tmp/pico-app-tests').status({})
        self.assertEqual(result, {'apps': []})
        self.assertEqual(observed['env']['HERMES_HOME'], str(Path('/tmp/pico-app-tests').resolve() / 'hermes'))
        for forbidden in ('TOOL_GATEWAY_USER_TOKEN', 'OPENAI_API_KEY', 'HERMES_OAUTH_TRACE'):
            self.assertNotIn(forbidden, observed['env'])
        self.assertIs(observed['stderr'], subprocess.DEVNULL)

    def test_unsafe_authorization_links_are_rejected(self):
        for value in ('http://example.com', 'https://me:password@example.com', 'https://example.com/\n', 'file:///tmp/thing'):
            self.assertIsNone(_connect_url(value))

    def test_safe_error_does_not_disclose_authorization_or_token(self):
        value = _safe_error('failed https://example.com/path?code=secret Authorization: token-value')
        self.assertNotIn('code=secret', value)
        self.assertNotIn('token-value', value)
        for message in ('Authorization: Bearer actual-token', 'Bearer actual-token', 'access_token=actual-token',
                        '"refresh_token": "actual-token"', 'client_secret=actual-token'):
            self.assertNotIn('actual-token', _safe_error(message))

    def test_public_cli_refuses_execution(self):
        script = Path(__file__).resolve().parents[1] / 'Backend/connected_apps.py'
        result = subprocess.run([sys.executable, str(script)], input='{"action":"call","name":"x"}',
                                capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout)['error']['code'], 'invalid_argument')
        self.assertEqual(result.stderr, '')

    def test_local_fallback_works_without_minting_a_nous_identity(self):
        host, helper = HermesFake(False), DevHelperFake()
        result = _dispatch('status', {}, host, fallback=helper)
        by_id = {row['id']: row for row in result['apps']}
        self.assertTrue(by_id['gmail']['connected'])
        self.assertTrue(by_id['figma']['connected'])
        self.assertEqual(by_id['gmail']['provider'], 'devhelper')
        self.assertFalse(by_id['twitter']['connected'])
        self.assertIn('developer app', by_id['twitter']['detail'])
        self.assertEqual(host.provisions, 0)

    def test_available_host_provider_is_preserved(self):
        host, helper = HermesFake(), DevHelperFake()
        result = _dispatch('status', {}, host, fallback=helper)
        self.assertEqual(helper.status_calls, [])
        self.assertEqual(result['apps'][0]['provider'], 'hermes')

    def test_fallback_connect_never_starts_unknown_authentication(self):
        host, helper = HermesFake(False), DevHelperFake()
        helper.connected = False
        result = _dispatch('connect', {'connectors': ['gmail', 'figma']}, host, fallback=helper)
        self.assertEqual(host.provisions, 0)
        self.assertEqual(host.connections, 0)
        self.assertEqual([row['state'] for row in result['apps']], ['needs_authorization'] * 2)
        self.assertNotIn('connect_url', json.dumps(result))

    def test_fallback_search_and_describe_keep_canonical_names(self):
        host, helper = HermesFake(), DevHelperFake()
        host.rows = [row for row in host.rows if row['connector'] not in ('gmail', 'figma')]
        result = _dispatch('search', {'query': 'mail', 'connectors': ['gmail']}, host, fallback=helper)
        self.assertEqual(set(result['tools']), {'connectors__gmail__LIST'})
        result = _dispatch('describe', {'names': ['connectors__gmail__LIST']}, host, fallback=helper)
        self.assertEqual(result['tools']['connectors__gmail__LIST']['provider'], 'devhelper')

    def test_fallback_status_describe_account_mismatch_is_rejected(self):
        host, helper = HermesFake(False), DevHelperFake()
        helper.changed_account = 'another-account@example.com'
        with self.assertRaises(ConnectedAppError) as raised:
            _dispatch('call', {'name': 'connectors__gmail__LIST', 'arguments': {}}, host, fallback=helper)
        self.assertEqual(raised.exception.code, 'account_changed')
        self.assertEqual(helper.execute_calls, [])

    def test_fallback_call_checks_approved_contract_and_current_schema(self):
        host, helper = HermesFake(False), DevHelperFake()
        contract = _dispatch('describe', {'names': ['connectors__gmail__LIST']}, host, fallback=helper)['tools']['connectors__gmail__LIST']
        result = _dispatch('call', {'name': 'connectors__gmail__LIST', 'arguments': {}, 'expected_contract': contract}, host, fallback=helper)
        self.assertFalse(result['verified'])
        self.assertEqual(helper.execute_calls[0]['expected_contract'], contract)
        contract['accounts'] = [{'label': 'old-account@example.com', 'active': True}]
        with self.assertRaises(ConnectedAppError) as raised:
            _dispatch('call', {'name': 'connectors__gmail__LIST', 'arguments': {}, 'expected_contract': contract}, host, fallback=helper)
        self.assertEqual(raised.exception.code, 'account_changed')
        self.assertEqual(len(helper.execute_calls), 1)
        with self.assertRaises(ConnectedAppError):
            _dispatch('call', {'name': 'connectors__gmail__LIST', 'arguments': {'unexpected': True}}, host, fallback=helper)
        self.assertEqual(len(helper.execute_calls), 1)

    def test_x_status_keeps_user_authorization_requirement(self):
        host, x = HermesFake(False), DevHelperFake()
        x.connected = False
        x.status = lambda app: {'connected': False, 'state': 'needs_authorization', 'accounts': [],
                                'detail': 'Register your X developer app and complete xurl authorization yourself.'}
        result = _dispatch('connect', {'connectors': ['twitter']}, host, xprovider=x)
        self.assertEqual(result['apps'][0]['state'], 'needs_authorization')
        self.assertFalse(result['apps'][0]['connected'])
        self.assertEqual(result['apps'][0]['provider'], 'xurl')
        self.assertIn('developer app', result['apps'][0]['detail'])
        self.assertEqual(host.provisions, 0)
        self.assertEqual(host.connections, 0)

    def test_authenticated_x_routes_canonical_tools_only_to_x_provider(self):
        host, helper, x = HermesFake(False), DevHelperFake(), DevHelperFake()
        result = _dispatch('describe', {'names': ['connectors__twitter__LIST']}, host, fallback=helper, xprovider=x)
        contract = result['tools']['connectors__twitter__LIST']
        self.assertEqual(contract['provider'], 'xurl')
        result = _dispatch('call', {'name': 'connectors__twitter__LIST', 'arguments': {}, 'expected_contract': contract},
                           host, fallback=helper, xprovider=x)
        self.assertFalse(result['verified'])
        self.assertEqual(len(x.execute_calls), 1)
        self.assertEqual(helper.execute_calls, [])

    def test_figma_describe_does_not_read_gmail_or_x_profiles(self):
        host, helper, x = HermesFake(False), DevHelperFake(), DevHelperFake()
        result = _dispatch('describe', {'names': ['connectors__figma__LIST']}, host, fallback=helper, xprovider=x)
        self.assertEqual(set(result['tools']), {'connectors__figma__LIST'})
        self.assertEqual(helper.status_calls, ['figma'])
        self.assertEqual(x.status_calls, [])
        self.assertEqual(host.provisions, 0)

    def test_specific_status_and_call_inspect_only_the_requested_provider(self):
        host, helper, x = HermesFake(False), DevHelperFake(), DevHelperFake()
        result = _dispatch('status', {'connectors': ['gmail']}, host, fallback=helper, xprovider=x)
        self.assertEqual([row['id'] for row in result['apps']], ['gmail'])
        self.assertEqual(helper.status_calls, ['gmail'])
        self.assertEqual(x.status_calls, [])
        helper.status_calls.clear()
        _dispatch('call', {'name': 'connectors__figma__LIST', 'arguments': {}}, host, fallback=helper, xprovider=x)
        self.assertEqual(helper.status_calls, ['figma'])
        self.assertEqual(x.status_calls, [])

    def test_unsupported_content_tool_does_not_inspect_any_account(self):
        host, helper, x = HermesFake(False), DevHelperFake(), DevHelperFake()
        with self.assertRaises(ConnectedAppError):
            _dispatch('describe', {'names': ['connectors__slack__LIST']}, host, fallback=helper, xprovider=x)
        self.assertEqual(helper.status_calls, [])
        self.assertEqual(x.status_calls, [])


if __name__ == '__main__':
    unittest.main()
