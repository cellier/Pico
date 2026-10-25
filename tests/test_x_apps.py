"""Official X CLI mapping with a fake process; no auth or live writes."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from x_apps import PREFIX, TOOLS, XAppError, XApps, _auth_selection


AUTH = '''▸ fixture-app  [client_id: PRIVATE-CREDENTIAL-HINT…]
      redirect_uri: http://localhost:8080/callback  [built-in default]
    ▸ oauth2: fixtureuser
      oauth1: –
      bearer: –
'''


class FakeXurl:
    def __init__(self):
        self.calls = []
        self.auth = AUTH
        self.user = {'id': '123456789', 'username': 'fixtureuser', 'name': 'Fixture User'}
        self.result = {'data': {'id': '987654321', 'text': 'Fixture response'}}
        self.code = 0
        self.failure = None

    def __call__(self, command, **options):
        self.calls.append((copy.deepcopy(command), copy.deepcopy(options)))
        if command[1:] == ['auth', 'status']:
            return subprocess.CompletedProcess(command, 0, stdout=self.auth)
        if command[-1] == '/2/users/me':
            return subprocess.CompletedProcess(command, 0, stdout=json.dumps({'data': self.user}))
        if self.failure:
            raise self.failure
        raw = self.result if isinstance(self.result, str) else json.dumps(self.result)
        return subprocess.CompletedProcess(command, self.code, stdout=raw)


class XAppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.fake = FakeXurl()
        self.apps = XApps(self.temp.name, runner=self.fake, executable='/fixture/xurl')

    def tearDown(self):
        self.temp.cleanup()

    def request(self, tool, arguments):
        name = PREFIX + tool
        return {'name': name, 'arguments': arguments, 'operation_id': 'fixture-x-operation',
                'expected_contract': self.apps.describe([name])['tools'][name]}

    def assert_error(self, code, callback):
        with self.assertRaises(XAppError) as caught:
            callback()
        self.assertEqual(caught.exception.code, code)
        return caught.exception

    def actual_commands(self):
        return [command for command, _ in self.fake.calls
                if command[1:] != ['auth', 'status'] and command[-1] != '/2/users/me']

    def test_missing_user_setup_is_truthful_and_never_starts_oauth(self):
        self.fake.auth = "No apps registered. Use 'xurl auth apps add' to register one."
        status = self.apps.status('twitter')
        self.assertFalse(status['connected'])
        self.assertEqual(status['state'], 'needs_authorization')
        self.assertEqual(status['accounts'], [])
        self.assertIn('yourself', status['detail'])
        self.assertIn('Do not paste', status['detail'])
        self.assertEqual([command[1:] for command, _ in self.fake.calls], [['auth', 'status']])

    def test_connected_status_returns_only_verified_identity_without_credential_hints(self):
        status = self.apps.status('x')
        self.assertTrue(status['connected'])
        self.assertEqual(status['provider'], 'xurl')
        self.assertEqual(status['accounts'][0]['alias'], 'xurl:fixture-app:123456789')
        self.assertEqual(status['accounts'][0]['label'], '@fixtureuser')
        self.assertNotIn('PRIVATE-CREDENTIAL', json.dumps(status))
        self.assertNotIn('redirect_uri', json.dumps(status))
        self.assertEqual(self.fake.calls[0][0][1:], ['auth', 'status'])
        self.assertEqual(self.fake.calls[1][0][1:], ['--app', 'fixture-app', '--auth', 'oauth2',
                                                  '--username', 'fixtureuser', '/2/users/me'])

    def test_default_app_without_credentials_is_not_substituted_for_another_app(self):
        self.fake.auth = '''▸ empty [no credentials]
      oauth2: (none)
      oauth1: –
      bearer: –
  other [client_id: PRIVATE-HINT…]
    ▸ oauth2: fixtureuser
      oauth1: –
      bearer: –
'''
        self.assertFalse(self.apps.status()['connected'])
        self.assertEqual(len(self.fake.calls), 1)

    def test_multiple_oauth_users_without_default_are_not_guessed(self):
        self.fake.auth = AUTH.replace('    ▸ oauth2: fixtureuser',
                                     '      oauth2: fixtureuser\n      oauth2: somebody')
        self.assertFalse(self.apps.status()['connected'])
        self.assertEqual(len(self.fake.calls), 1)

    def test_single_user_without_marker_is_unambiguous(self):
        self.fake.auth = AUTH.replace('    ▸ oauth2:', '      oauth2:')
        self.assertTrue(self.apps.status()['connected'])

    def test_oauth1_selection_remains_bound_to_exact_verified_user(self):
        self.fake.auth = AUTH.replace('    ▸ oauth2: fixtureuser', '      oauth2: (none)').replace('oauth1: –', 'oauth1: ✓')
        status = self.apps.status()
        self.assertTrue(status['connected'])
        self.assertIn('oauth1', self.fake.calls[1][0])
        self.assertNotIn('--username', self.fake.calls[1][0])

    def test_bearer_only_does_not_claim_an_authenticated_user(self):
        self.fake.auth = AUTH.replace('    ▸ oauth2: fixtureuser', '      oauth2: (none)').replace('bearer: –', 'bearer: ✓')
        self.assertFalse(self.apps.status()['connected'])
        self.assertEqual(len(self.fake.calls), 1)

    def test_actual_user_must_match_selected_user(self):
        self.fake.user['username'] = 'someoneelse'
        result = self.apps.status()
        self.assertFalse(result['connected'])
        self.assertEqual(result['accounts'], [])

    def test_invalid_identity_cannot_become_a_connected_account(self):
        for bad in ({}, {'id': '../not-an-id', 'username': 'fixtureuser'},
                    {'id': '123', 'username': '--danger'}, {'id': 123, 'username': 'fixtureuser'}):
            with self.subTest(bad=bad):
                self.fake.user = bad
                self.assertFalse(self.apps.status()['connected'])

    def test_catalogue_has_exact_small_reviewed_facets_and_schemas(self):
        tools = self.apps.search('twitter', 'write read search X posts')['tools']
        self.assertEqual(set(tools), {PREFIX + key for key in TOOLS})
        metadata = self.apps.describe([PREFIX + key for key in TOOLS])['tools']
        self.assertEqual(metadata[PREFIX + 'X_DELETE_POST']['facet'], 'destructive')
        self.assertEqual(metadata[PREFIX + 'X_READ_POST']['facet'], 'read')
        self.assertEqual(metadata[PREFIX + 'X_CREATE_POST']['facet'], 'write')
        for tool in metadata.values():
            self.assertEqual(tool['provider'], 'xurl')
            self.assertFalse(tool['parameters']['additionalProperties'])
            self.assertEqual(len(tool['accounts']), 1)
        self.assertFalse(any('DM' in name or 'MEDIA' in name or 'RAW' in name for name in tools))

    def test_unsupported_app_and_unreviewed_tool_never_run_cli(self):
        self.assert_error('unsupported_app', lambda: self.apps.status('gmail'))
        self.assert_error('tool_not_found', lambda: self.apps.describe(['connectors__twitter__raw']))
        self.assert_error('tool_not_found', lambda: self.apps.call({'name': PREFIX + 'X_RAW', 'arguments': {}}))
        self.assertEqual(self.fake.calls, [])

    def test_create_body_is_exact_json_and_fixed_endpoint_without_shell_interpretation(self):
        text = '--verbose\n$(touch /tmp/never-run) `not-a-command` "中文"'
        result = self.apps.call(self.request('X_CREATE_POST', {'text': text}))
        command = self.actual_commands()[-1]
        self.assertEqual(command[command.index('-X') + 1:command.index('-d')], ['POST', '/2/tweets'])
        self.assertEqual(json.loads(command[-1]), {'text': text})
        self.assertNotIn('--verbose', command)
        self.assertTrue(result['submitted'])
        self.assertFalse(result['verified'])
        self.assertNotIn('operation_id', command)

    def test_reply_nested_api_field_is_correct(self):
        self.apps.call(self.request('X_REPLY_POST', {'post_id': '123456', 'text': 'Exact reply.'}))
        command = self.actual_commands()[-1]
        self.assertEqual(command[command.index('-X') + 1:command.index('-d')], ['POST', '/2/tweets'])
        self.assertEqual(json.loads(command[-1]), {'reply': {'in_reply_to_tweet_id': '123456'}, 'text': 'Exact reply.'})

    def test_edit_uses_previous_post_id_exact_text_and_requires_new_id_readback(self):
        text = 'Exact edited text.\n中文和 "quotes"，不截断。'
        request = self.request('X_EDIT_POST', {'post_id': '1234567890123456789', 'text': text})
        self.assertEqual(request['expected_contract']['facet'], 'write')
        self.assertIn('new post ID', request['expected_contract']['description'])
        result = self.apps.call(request)
        command = self.actual_commands()[-1]
        self.assertEqual(command[command.index('-X') + 1:command.index('-d')], ['POST', '/2/tweets'])
        self.assertEqual(json.loads(command[-1]), {'text': text,
                                                  'edit_options': {'previous_post_id': '1234567890123456789'}})
        self.assertNotIn('previous_tweet_id', command[-1])
        self.assertEqual(result['result']['data']['id'], '987654321')
        self.assertTrue(result['submitted'])
        self.assertFalse(result['verified'])

    def test_edit_does_not_dispatch_after_the_reviewed_account_changes(self):
        request = self.request('X_EDIT_POST', {'post_id': '123', 'text': 'An exact requested edit.'})
        self.fake.calls.clear()
        self.fake.user['id'] = '777'
        self.assert_error('account_changed', lambda: self.apps.call(request))
        self.assertEqual(self.actual_commands(), [])

    def test_delete_like_unlike_only_use_exact_typed_ids(self):
        expected = {
            'X_DELETE_POST': ('DELETE', '/2/tweets/987'),
            'X_LIKE_POST': ('POST', '/2/users/123456789/likes'),
            'X_UNLIKE_POST': ('DELETE', '/2/users/123456789/likes/987'),
        }
        for name, (method, path) in expected.items():
            with self.subTest(name=name):
                self.apps.call(self.request(name, {'post_id': '987'}))
                command = self.actual_commands()[-1]
                self.assertEqual(command[command.index('-X') + 1:command.index('-X') + 3], [method, path])
                if name == 'X_LIKE_POST':
                    self.assertEqual(json.loads(command[-1]), {'tweet_id': '987'})
                else:
                    self.assertNotIn('-d', command)

    def test_search_is_fixed_get_with_encoded_query_and_pagination(self):
        query = 'from:fixtureuser "two words" & https://untrusted.invalid/path'
        result = self.apps.call(self.request('X_SEARCH_POSTS', {'query': query, 'max_results': 20, 'next_token': 'fixture/token=='}))
        command = self.actual_commands()[-1]
        path = urlsplit(command[-1])
        self.assertEqual(path.path, '/2/tweets/search/recent')
        self.assertEqual(path.scheme, '')
        params = parse_qs(path.query)
        self.assertEqual(params['query'], [query])
        self.assertEqual(params['next_token'], ['fixture/token=='])
        self.assertEqual(params['max_results'], ['20'])
        self.assertFalse(result['submitted'])
        self.assertFalse(result['verified'])

    def test_read_post_uses_observed_digit_id_and_returns_raw_x_data(self):
        result = self.apps.call(self.request('X_READ_POST', {'post_id': '123456'}))
        self.assertTrue(self.actual_commands()[-1][-1].startswith('/2/tweets/123456?'))
        self.assertEqual(result['result'], self.fake.result)

    def test_schema_rejects_url_path_credentials_media_and_excess_without_any_cli(self):
        examples = [
            ('X_READ_POST', {'post_id': 'https://x.com/name/status/123'}),
            ('X_DELETE_POST', {'post_id': '../users/123'}),
            ('X_CREATE_POST', {'text': ''}),
            ('X_CREATE_POST', {'text': 'x' * 25001}),
            ('X_CREATE_POST', {'text': 'valid', 'client_secret': 'never-accepted'}),
            ('X_CREATE_POST', {'text': 'valid', 'file': '/private/file'}),
            ('X_REPLY_POST', {'post_id': '123'}),
            ('X_EDIT_POST', {'post_id': '1' * 20, 'text': 'Too long an ID.'}),
            ('X_EDIT_POST', {'post_id': '123', 'text': 'Exact edit.', 'previous_tweet_id': '123'}),
            ('X_SEARCH_POSTS', {'query': 'x', 'max_results': 9}),
            ('X_SEARCH_POSTS', {'query': 'x', 'max_results': 101}),
            ('X_SEARCH_POSTS', {'query': 'x', 'endpoint': 'https://untrusted.invalid'}),
        ]
        for key, arguments in examples:
            with self.subTest(key=key, arguments=arguments):
                self.assert_error('invalid_argument', lambda: self.apps.call(
                    {'name': PREFIX + key, 'arguments': arguments}))
        self.assertEqual(self.fake.calls, [])

    def test_changed_identity_or_expected_contract_never_dispatches_write(self):
        request = self.request('X_CREATE_POST', {'text': 'Exact fixture.'})
        self.fake.calls.clear()
        self.fake.user['id'] = '777'
        self.assert_error('account_changed', lambda: self.apps.call(request))
        self.assertEqual(self.actual_commands(), [])
        self.fake.user['id'] = '123456789'
        request['expected_contract']['facet'] = 'read'
        self.assert_error('account_changed', lambda: self.apps.call(request))
        self.assertEqual(self.actual_commands(), [])

    def test_missing_expected_contract_is_not_an_authorized_call(self):
        self.assert_error('account_changed', lambda: self.apps.call(
            {'name': PREFIX + 'X_CREATE_POST', 'arguments': {'text': 'No reviewed account.'}}))
        self.assertEqual(self.actual_commands(), [])

    def test_errors_never_return_text_argv_or_credential_material(self):
        request = self.request('X_CREATE_POST', {'text': 'PRIVATE-POST-TEXT'})
        self.fake.failure = subprocess.CalledProcessError(1, ['xurl', 'PRIVATE-POST-TEXT', 'PRIVATE-CREDENTIAL'],
                                                        stderr='PRIVATE-CREDENTIAL')
        error = self.assert_error('x_request_failed', lambda: self.apps.call(request))
        self.assertTrue(error.outcome_unknown)
        self.assertNotIn('PRIVATE', str(error))

    def test_api_errors_timeouts_and_invalid_acknowledgements_are_not_success(self):
        request = self.request('X_CREATE_POST', {'text': 'Exact fixture.'})
        for response, code in (({'errors': [{'message': 'denied'}]}, 'x_request_failed'),
                               ({'errors': [{'message': 'CreditsDepleted'}]}, 'plan_required'),
                               ({'status': 429}, 'rate_limited'), ({}, 'outcome_unknown'),
                               ('not json', 'x_request_failed')):
            with self.subTest(response=response):
                self.fake.result = response
                error = self.assert_error(code, lambda: self.apps.call(request))
                self.assertTrue(error.outcome_unknown)
        self.fake.failure = subprocess.TimeoutExpired(['xurl', 'PRIVATE'], 45)
        self.assertTrue(self.assert_error('timeout', lambda: self.apps.call(request)).outcome_unknown)

    def test_cli_environment_does_not_inherit_app_secrets_or_endpoint_overrides(self):
        with patch.dict(os.environ, {'CLIENT_SECRET': 'private', 'API_BASE_URL': 'https://untrusted.invalid',
                                     'AUTHORIZATION': 'private', 'HOME': '/fixture-home'}):
            self.apps.status()
        for _, options in self.fake.calls:
            self.assertEqual(options['env']['HOME'], '/fixture-home')
            self.assertNotIn('CLIENT_SECRET', options['env'])
            self.assertNotIn('API_BASE_URL', options['env'])
            self.assertNotIn('AUTHORIZATION', options['env'])
        for command, _ in self.fake.calls:
            self.assertFalse(set(command) & {'-v', '--verbose', 'token', 'apps', '--client-secret'})
            self.assertNotEqual(command[1:3], ['auth', 'oauth2'])

    def test_auth_status_parser_discards_ansi_and_requires_simple_app_name(self):
        self.assertEqual(_auth_selection('\x1b[32m' + AUTH + '\x1b[0m')['app'], 'fixture-app')
        self.assert_error('needs_authorization', lambda: _auth_selection(AUTH.replace('fixture-app', '--untrusted-flag')))


if __name__ == '__main__':
    unittest.main()
