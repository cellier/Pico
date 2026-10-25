"""Reviewed X API operations through the official xurl CLI.

No credential files are inspected here. User setup and OAuth stay outside Pico;
the parent owns exact authorization, cancellation and durable write replay.
Official command/API mapping reviewed against xdevplatform/xurl cli/root.go,
cli/auth.go and api/shortcuts.go, and docs.x.com/x-api/posts/create-post.md
for edit_options.previous_post_id (2026-10-24).
"""
from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import urlencode


PREFIX = 'connectors__twitter__'
MAX_OUTPUT = 2_000_000
ENV_KEYS = frozenset(('PATH', 'HOME', 'USER', 'LANG', 'LC_ALL', 'TMPDIR'))
SETUP_URL = 'https://github.com/xdevplatform/xurl#authentication'
SETUP_DETAIL = ('X requires your own developer app. Complete the official xurl one-time app setup and '
                'OAuth yourself in Terminal, then choose its default app/account and refresh Pico. '
                'Do not paste app secrets or tokens into Chat.')


class XAppError(Exception):
    def __init__(self, code, message, *, outcome_unknown=False):
        self.code, self.message, self.outcome_unknown = code, message, outcome_unknown
        super().__init__(message)


def _object(properties=None, required=None):
    return {'type': 'object', 'properties': properties or {}, 'required': required or [],
            'additionalProperties': False}


POST_ID = {'type': 'string', 'pattern': '^[0-9]{1,25}$',
           'description': 'Exact post ID resolved from a real X read. Use digits, not a URL.'}
EDIT_POST_ID = dict(POST_ID, pattern='^[0-9]{1,19}$')
TEXT = {'type': 'string', 'minLength': 1, 'maxLength': 25_000,
        'description': 'Exact user-requested post text. No trimming or silent shortening; X plan limits still apply.'}
TOOLS = {
    'X_GET_ME': {'facet': 'read', 'description': 'Read the exact authenticated X user profile.',
                 'parameters': _object()},
    'X_READ_POST': {'facet': 'read', 'description': 'Read one X post, its author and engagement metrics.',
                   'parameters': _object({'post_id': POST_ID}, ['post_id'])},
    'X_SEARCH_POSTS': {'facet': 'read',
                      'description': 'Search recent raw X posts. Keep the query focused; inspect pagination.',
                      'parameters': _object({
                          'query': {'type': 'string', 'minLength': 1, 'maxLength': 512},
                          'max_results': {'type': 'integer', 'minimum': 10, 'maximum': 100},
                          'next_token': {'type': 'string', 'minLength': 1, 'maxLength': 2048}}, ['query'])},
    'X_CREATE_POST': {'facet': 'write', 'description': 'Publish the exact user-requested text as a new X post.',
                     'parameters': _object({'text': TEXT}, ['text'])},
    'X_EDIT_POST': {'facet': 'write',
                   'description': 'Edit the exact user-requested owned X post. X enforces its plan and edit eligibility limits; the edit returns a new post ID that must be freshly read back.',
                   'parameters': _object({'post_id': EDIT_POST_ID, 'text': TEXT}, ['post_id', 'text'])},
    'X_REPLY_POST': {'facet': 'write', 'description': 'Reply with exact user-requested text to an exact observed X post.',
                    'parameters': _object({'post_id': POST_ID, 'text': TEXT}, ['post_id', 'text'])},
    'X_DELETE_POST': {'facet': 'destructive', 'description': 'Delete the exact requested X post owned by this account.',
                      'parameters': _object({'post_id': POST_ID}, ['post_id'])},
    'X_LIKE_POST': {'facet': 'write', 'description': 'Like the exact user-requested X post as the connected account.',
                    'parameters': _object({'post_id': POST_ID}, ['post_id'])},
    'X_UNLIKE_POST': {'facet': 'write', 'description': 'Remove this account\'s like from the exact user-requested X post.',
                      'parameters': _object({'post_id': POST_ID}, ['post_id'])},
}


def _json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False)


def _app(value):
    if value not in ('twitter', 'x'):
        raise XAppError('unsupported_app', 'This provider supports X / Twitter only.')


def _name(name):
    if not isinstance(name, str) or not name.startswith(PREFIX) or name[len(PREFIX):] not in TOOLS:
        raise XAppError('tool_not_found', 'Choose an exact reviewed X tool returned by app search.')
    return name[len(PREFIX):]


def _auth_selection(raw):
    """Parse only official auth-status labels; never return credential hints."""
    raw = re.sub(r'\x1b\[[0-9;]*m', '', raw)
    selected = None
    current = None
    for line in raw.splitlines():
        match = re.fullmatch(r'([ ▸]*)\s*([^\[\]\r\n]+?)\s+\[[^\r\n]*\]\s*', line)
        if match and not line.lstrip().startswith(('redirect_uri:', 'stored_redirect_uri:')):
            current = {'app': match[2].strip(), 'default': '▸' in match[1],
                       'credentials': '[client_id:' in line, 'users': [], 'selected_user': None,
                       'oauth1': False}
            if current['default']:
                selected = current
            continue
        if current is None:
            continue
        user = re.fullmatch(r'\s*(▸\s*)?oauth2:\s*([A-Za-z0-9_]{1,15})\s*', line)
        if user:
            current['users'].append(user[2])
            if user[1]:
                current['selected_user'] = user[2]
        if re.fullmatch(r'\s*oauth1:\s*✓\s*', line):
            current['oauth1'] = True
    if not selected or not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,79}', selected['app']):
        raise XAppError('needs_authorization', SETUP_DETAIL)
    user = selected['selected_user']
    if not user and len(selected['users']) == 1:
        user = selected['users'][0]
    if user and selected['credentials']:
        return {'app': selected['app'], 'auth': 'oauth2', 'username': user}
    if selected['oauth1'] and not selected['users']:
        return {'app': selected['app'], 'auth': 'oauth1'}
    raise XAppError('needs_authorization', SETUP_DETAIL)


class XApps:
    def __init__(self, data, workspace=None, *, runner=None, executable=None):
        self.data = Path(data).expanduser().resolve()
        self.workspace = Path(workspace).resolve() if workspace else None
        self.runner, self.executable = runner, executable

    def _binary(self):
        if self.executable:
            return str(self.executable)
        # The development app embeds Backend several directories below the
        # checkout. Walk its ancestors without assuming the source-file depth.
        paths = [root / suffix for root in Path(__file__).resolve().parents
                 for suffix in ('.runtime/xurl/node_modules/.bin/xurl',
                                '.runtime/xurl/bin/xurl', '.runtime/xurl/xurl')]
        paths.extend([Path.home() / '.local/bin/xurl', Path('/opt/homebrew/bin/xurl'),
                      Path('/usr/local/bin/xurl')])
        for path in paths:
            if path.is_file() and os.access(path, os.X_OK):
                return str(path)
        raise XAppError('not_installed', 'The official X command tool is not installed. Install xurl, then refresh Pico.')

    def _run(self, arguments, *, write=False, text=False):
        # Never log argv, interpolate through a shell, inherit provider secrets,
        # or return stderr. The official CLI accepts JSON only as a -d argument.
        command = [self._binary(), *arguments]
        env = {key: value for key, value in os.environ.items() if key in ENV_KEYS}
        try:
            if self.runner:
                response = self.runner(command, env=env, timeout=45)
                code, raw = response.returncode, response.stdout
            else:
                with tempfile.TemporaryDirectory(prefix='pico-xurl-') as cwd, tempfile.TemporaryFile() as output:
                    response = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=output,
                                              stderr=subprocess.DEVNULL, env=env, cwd=cwd,
                                              timeout=45, check=False, shell=False)
                    output.seek(0)
                    raw = output.read(MAX_OUTPUT + 1)
                code = response.returncode
            if isinstance(raw, bytes):
                raw = raw.decode('utf-8')
            if not isinstance(raw, str) or len(raw.encode()) > MAX_OUTPUT:
                raise XAppError('invalid_response', 'X returned an oversized or invalid response.', outcome_unknown=write)
            if text:
                if code:
                    raise XAppError('needs_authorization', SETUP_DETAIL)
                return raw
            value = json.loads(raw)
            if not isinstance(value, dict):
                raise XAppError('invalid_response', 'X returned an invalid response.', outcome_unknown=write)
            if code or value.get('errors') or value.get('error') or value.get('status', 0) in (401, 403, 429):
                serialized = _json(value).lower()
                if any(token in serialized for token in ('creditsdepleted', 'client-forbidden', 'client-not-enrolled')):
                    raise XAppError('plan_required', 'X requires API enrollment or available API credits for this action.', outcome_unknown=write)
                if value.get('status') == 429 or 'rate limit' in serialized:
                    raise XAppError('rate_limited', 'X rate-limited this action. Inspect the current result before retrying a change.', outcome_unknown=write)
                raise XAppError('x_request_failed', 'X did not confirm this action. Check its authorization, plan and actual item.', outcome_unknown=write)
            return value
        except XAppError:
            raise
        except subprocess.TimeoutExpired:
            raise XAppError('timeout', 'X did not answer in time. Inspect its actual state before retrying a change.', outcome_unknown=write) from None
        except Exception:
            # CalledProcessError, OSError and JSON errors may contain argv/text.
            raise XAppError('x_request_failed', 'The X request could not complete. Check its authorization and current state.', outcome_unknown=write) from None

    @staticmethod
    def _options(selection):
        values = ['--app', selection['app'], '--auth', selection['auth']]
        if selection.get('username'):
            values.extend(['--username', selection['username']])
        return values

    def _identity(self):
        selection = _auth_selection(self._run(['auth', 'status'], text=True))
        profile = self._run([*self._options(selection), '/2/users/me'])
        user = profile.get('data')
        if (not isinstance(user, dict) or not isinstance(user.get('id'), str) or
                not re.fullmatch(r'[0-9]{1,25}', user['id']) or
                not isinstance(user.get('username'), str) or
                not re.fullmatch(r'[A-Za-z0-9_]{1,15}', user['username'])):
            raise XAppError('needs_authorization', 'X did not identify an authenticated user account. ' + SETUP_DETAIL)
        if selection.get('username') and selection['username'].lower() != user['username'].lower():
            raise XAppError('account_changed', 'The selected X user differs from the authenticated account. Choose the correct default account yourself, then refresh Pico.')
        account = {'alias': f"xurl:{selection['app']}:{user['id']}",
                   'label': '@' + user['username'], 'active': True, 'retired': False, 'status': 'connected'}
        return selection, account, user

    def status(self, app='twitter'):
        _app(app)
        try:
            _, account, _ = self._identity()
            return {'connected': True, 'state': 'connected', 'accounts': [account],
                    'detail': 'Connected through your user-authorized official X account.', 'provider': 'xurl'}
        except XAppError as error:
            return {'connected': False, 'state': 'needs_authorization' if error.code != 'not_installed' else 'not_installed',
                    'accounts': [], 'detail': error.message, 'setup_url': SETUP_URL, 'provider': 'xurl'}

    def search(self, app, query):
        _app(app)
        if not isinstance(query, str) or not 1 <= len(query.strip()) <= 2000:
            raise XAppError('invalid_argument', 'Use a focused description of the desired X action.')
        # This small reviewed catalogue contains no account content; unfamiliar
        # names still require describe before calling through the parent gate.
        return {'tools': {PREFIX + name: {'description': value['description']}
                          for name, value in TOOLS.items()}, 'provider': 'xurl'}

    def describe(self, names):
        if not isinstance(names, list) or not 1 <= len(names) <= 10 or len(names) != len(set(names)):
            raise XAppError('invalid_argument', 'Describe one to ten exact X tools.')
        short = [_name(name) for name in names]
        _, account, _ = self._identity()
        return {'tools': {name: dict(copy.deepcopy(TOOLS[key]), accounts=[account], provider='xurl')
                          for name, key in zip(names, short)}}

    def call(self, request):
        if not isinstance(request, dict):
            raise XAppError('invalid_argument', 'Use a bounded X operation object.')
        key = _name(request.get('name'))
        args = request.get('arguments')
        try:
            from jsonschema import Draft202012Validator
            valid = isinstance(args, dict) and not next(Draft202012Validator(TOOLS[key]['parameters']).iter_errors(args), None)
            bounded = valid and len(_json(args).encode()) <= 160_000
        except Exception:
            bounded = False
        if not bounded:
            raise XAppError('invalid_argument', 'Arguments do not match the exact reviewed X operation schema.')
        selection, account, user = self._identity()
        actual = dict(copy.deepcopy(TOOLS[key]), accounts=[account], provider='xurl')
        expected = request.get('expected_contract')
        if not isinstance(expected, dict) or _json(expected) != _json(actual):
            raise XAppError('account_changed', 'The X account or operation changed. Inspect its current account and schema before continuing.')
        method, body = 'GET', None
        if key == 'X_GET_ME':
            path = '/2/users/me'
        elif key == 'X_READ_POST':
            path = '/2/tweets/' + args['post_id'] + '?' + urlencode({
                'tweet.fields': 'created_at,public_metrics,conversation_id,in_reply_to_user_id,referenced_tweets,entities,attachments',
                'expansions': 'author_id,referenced_tweets.id', 'user.fields': 'username,name,verified'})
        elif key == 'X_SEARCH_POSTS':
            query = {'query': args['query'], 'max_results': args.get('max_results', 10),
                     'tweet.fields': 'created_at,public_metrics,conversation_id,entities',
                     'expansions': 'author_id', 'user.fields': 'username,name,verified'}
            if args.get('next_token'):
                query['next_token'] = args['next_token']
            path = '/2/tweets/search/recent?' + urlencode(query)
        elif key in ('X_CREATE_POST', 'X_EDIT_POST', 'X_REPLY_POST'):
            method, path, body = 'POST', '/2/tweets', {'text': args['text']}
            if key == 'X_REPLY_POST':
                body['reply'] = {'in_reply_to_tweet_id': args['post_id']}
            elif key == 'X_EDIT_POST':
                body['edit_options'] = {'previous_post_id': args['post_id']}
        elif key == 'X_DELETE_POST':
            method, path = 'DELETE', '/2/tweets/' + args['post_id']
        elif key == 'X_LIKE_POST':
            method, path, body = 'POST', '/2/users/' + user['id'] + '/likes', {'tweet_id': args['post_id']}
        else:  # X_UNLIKE_POST; every other name was rejected before execution.
            method, path = 'DELETE', '/2/users/' + user['id'] + '/likes/' + args['post_id']
        command = [*self._options(selection), '-X', method, path]
        if body is not None:
            command.extend(['-d', _json(body)])
        write = TOOLS[key]['facet'] != 'read'
        result = self._run(command, write=write)
        if write and not result.get('data'):
            raise XAppError('outcome_unknown', 'X returned no change result. Read the actual post or engagement state before any retry.', outcome_unknown=True)
        return {'result': result, 'submitted': write, 'verified': False, 'account': account,
                'provider': 'xurl'}
