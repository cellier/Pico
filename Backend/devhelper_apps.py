"""Gmail/Figma facade over the user's own DevHelper login.

Metadata comes from the current connector catalogue and schema. Calls use the
official stdio MCP server so message bodies never enter a process argument.
This module does not authenticate, copy credentials, or approve writes.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import select
import selectors
import shutil
import signal
import subprocess
import time

from zoom_connector import ZoomError, _result_error, _sanitize, _validate_arguments

APPS = {'gmail': ('google_mail', 'Gmail'), 'figma': ('figma', 'Figma')}
READ_TOOLS = {
    'gmail': frozenset((
        'GMAIL_FETCH_EMAILS', 'GMAIL_GET_ATTACHMENT', 'GMAIL_GET_AUTO_FORWARDING',
        'GMAIL_GET_DRAFT', 'GMAIL_GET_FILTER', 'GMAIL_GET_FORWARDING_ADDRESS',
        'GMAIL_GET_IMAP_SETTINGS', 'GMAIL_GET_LABEL', 'GMAIL_GET_LANGUAGE_SETTINGS',
        'GMAIL_GET_POP_SETTINGS', 'GMAIL_GET_PROFILE', 'GMAIL_GET_SEND_AS_ALIAS',
        'GMAIL_GET_VACATION_SETTINGS', 'GMAIL_LIST_DRAFTS', 'GMAIL_LIST_EMAIL_ATTACHMENTS',
        'GMAIL_LIST_FILTERS', 'GMAIL_LIST_FORWARDING_ADDRESSES', 'GMAIL_LIST_HISTORY',
        'GMAIL_LIST_LABELS', 'GMAIL_LIST_SEND_AS_ALIASES', 'GMAIL_LIST_THREADS',
        'GMAIL_READ_EMAIL', 'GMAIL_READ_THREAD', 'GMAIL_SEARCH_PEOPLE', 'zva_get_current_email',
    )),
    'figma': frozenset((
        'FIGMA_DESIGN_TOKENS_TO_TAILWIND', 'FIGMA_DETECT_BACKGROUND',
        'FIGMA_DISCOVER_FIGMA_RESOURCES', 'FIGMA_EXTRACT_DESIGN_TOKENS',
        'FIGMA_EXTRACT_PROTOTYPE_INTERACTIONS', 'FIGMA_GET_COMMENTS_IN_A_FILE',
        'FIGMA_GET_COMPONENT2', 'FIGMA_GET_COMPONENT_SET', 'FIGMA_GET_CURRENT_USER',
        'FIGMA_GET_FILES_IN_A_PROJECT', 'FIGMA_GET_FILE_COMPONENTS',
        'FIGMA_GET_FILE_COMPONENT_SETS', 'FIGMA_GET_FILE_JSON', 'FIGMA_GET_FILE_METADATA',
        'FIGMA_GET_FILE_NODES', 'FIGMA_GET_FILE_STYLES', 'FIGMA_GET_PROJECTS_IN_A_TEAM',
        'FIGMA_RENDER_IMAGES_OF_FILE_NODES',
    )),
}
WRITE_TOOLS = {
    'gmail': frozenset(('GMAIL_ADD_LABEL', 'GMAIL_CREATE_DRAFT', 'GMAIL_SEND_EMAIL', 'zva_send_email_message')),
    'figma': frozenset(('FIGMA_ADD_A_COMMENT_TO_A_FILE',)),
}
_IDENTIFIER = re.compile(r'^[A-Za-z][A-Za-z0-9_]{0,127}$')
_ENVIRONMENT = frozenset(('PATH', 'HOME', 'USER', 'LANG', 'LC_ALL', 'TMPDIR', 'SHELL'))


class DevHelperAppError(ValueError):
    def __init__(self, code, message, *, outcome_unknown=False):
        self.code, self.message, self.outcome_unknown = code, message, outcome_unknown
        super().__init__(message)


def operation_kind(app, tool):
    if tool in READ_TOOLS.get(app, ()):
        return 'read'
    if tool in WRITE_TOOLS.get(app, ()):
        return 'write'
    return 'unclassified'


def _failure(value, *, outcome_unknown=False):
    # Deliberately do not return the provider's diagnostic text: it may contain
    # OAuth URLs, query contents, credentials or a rejected email body.
    text = str(value).lower()
    if 'mail service not enabled' in text:
        return DevHelperAppError('needs_authorization',
            'This Google account does not have Gmail enabled. Connect a Gmail-enabled account.', outcome_unknown=outcome_unknown)
    if any(word in text for word in ('401', 'unauthorized', 'unauthenticated', 'not logged',
            'not authenticated', 'expired token', 'token expired', 'login required', 'invalid access token')):
        return DevHelperAppError('needs_authorization',
            'DevHelper sign-in is missing or expired. Connect this app again.', outcome_unknown=outcome_unknown)
    if any(word in text for word in ('403', 'forbidden', 'permission denied', 'insufficient scope', 'access denied')):
        return DevHelperAppError('permission_denied',
            'This account has not granted permission for this app action.', outcome_unknown=outcome_unknown)
    return DevHelperAppError('service_unavailable',
        'DevHelper could not complete the app request. No result has been verified.', outcome_unknown=outcome_unknown)


def _environment():
    result = {key: value for key, value in os.environ.items() if key in _ENVIRONMENT}
    result.update(NO_COLOR='1', CI='1')
    return result


def _unwrap_transport(value):
    # The connector MCP adapter can wrap the gateway's JSON-RPC response in
    # a text content block. Unwrap transport envelopes, never arbitrary data.
    for _ in range(8):
        if not isinstance(value, dict):
            return value
        if value.get('jsonrpc') == '2.0':
            if value.get('error'):
                raise _failure(json.dumps(value['error'], ensure_ascii=False))
            if 'result' in value:
                value = value['result']
                continue
        content = value.get('content')
        if isinstance(content, list) and len(content) == 1 and isinstance(content[0], dict) and content[0].get('type') == 'text':
            try:
                inner = json.loads(content[0].get('text', ''))
            except (ValueError, TypeError):
                break
            if isinstance(inner, dict) and inner.get('jsonrpc') == '2.0':
                value = inner
                continue
        break
    return value


def _stop(process):
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=3)


class _MCPCall:
    def __init__(self, executable, connector, timeout=60):
        self.deadline = time.monotonic() + timeout
        self.process = subprocess.Popen([executable, 'mcp', 'start', '--connector', connector],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=_environment(), start_new_session=True)
        os.set_blocking(self.process.stdin.fileno(), False)
        os.set_blocking(self.process.stdout.fileno(), False)
        self.buffer = bytearray()
        self.size = 0
        self.dispatched = False

    def close(self):
        _stop(self.process)
        self.process.stdin.close()
        self.process.stdout.close()

    def send(self, value):
        wire = json.dumps(value, ensure_ascii=False, allow_nan=False).encode() + b'\n'
        if len(wire) > 1_000_000:
            raise DevHelperAppError('invalid_argument', 'App arguments are too large for this request.')
        offset = 0
        while offset < len(wire):
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise DevHelperAppError('timeout', 'The app request timed out.', outcome_unknown=self.dispatched)
            if self.process.poll() is not None:
                raise _failure('', outcome_unknown=self.dispatched)
            if select.select([], [self.process.stdin], [], min(remaining, .2))[1]:
                try:
                    offset += os.write(self.process.stdin.fileno(), wire[offset:offset + 16384])
                except BlockingIOError:
                    continue
                except BrokenPipeError:
                    raise _failure('', outcome_unknown=self.dispatched) from None

    def receive(self, identity):
        while True:
            while b'\n' in self.buffer:
                line, _, tail = self.buffer.partition(b'\n')
                self.buffer = bytearray(tail)
                try:
                    value = json.loads(line)
                except (ValueError, TypeError):
                    raise DevHelperAppError('invalid_response', 'DevHelper returned an invalid app response.',
                                            outcome_unknown=self.dispatched) from None
                if not isinstance(value, dict):
                    continue
                if value.get('id') == identity and ('result' in value or 'error' in value):
                    if value.get('error'):
                        raise _failure(json.dumps(value['error']), outcome_unknown=self.dispatched)
                    return value['result']
                # No server-initiated credential/sampling requests are approved.
                if 'method' in value and 'id' in value:
                    if value['method'] == 'ping':
                        self.send({'jsonrpc': '2.0', 'id': value['id'], 'result': {}})
                    else:
                        self.send({'jsonrpc': '2.0', 'id': value['id'],
                                   'error': {'code': -32601, 'message': 'This client does not support that request.'}})
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise DevHelperAppError('timeout', 'The app request timed out.', outcome_unknown=self.dispatched)
            if not select.select([self.process.stdout], [], [], min(remaining, .2))[0]:
                if self.process.poll() is not None:
                    raise _failure('', outcome_unknown=self.dispatched)
                continue
            block = os.read(self.process.stdout.fileno(), 65536)
            if not block:
                raise _failure('', outcome_unknown=self.dispatched)
            self.size += len(block)
            if self.size > 4_000_000:
                raise DevHelperAppError('response_too_large', 'The app response was too large. Narrow this request.',
                                        outcome_unknown=self.dispatched)
            self.buffer.extend(block)

    def call(self, tool, arguments, schema):
        self.send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
                   'params': {'protocolVersion': '2024-11-05', 'capabilities': {},
                              'clientInfo': {'name': 'Pico Connected Apps', 'version': '1'}}})
        self.receive(1)
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        self.send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list', 'params': {}})
        listing = self.receive(2)
        tools = listing.get('tools', []) if isinstance(listing, dict) else []
        row = next((row for row in tools if isinstance(row, dict) and row.get('name') == tool), None)
        if row is None or row.get('inputSchema') != schema:
            raise DevHelperAppError('schema_changed', 'The app tool changed. Discover its current schema before trying again.')
        self.dispatched = True
        self.send({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call',
                   'params': {'name': tool, 'arguments': arguments}})
        result = _unwrap_transport(self.receive(3))
        if _result_error(result):
            raise _failure(json.dumps(result, ensure_ascii=False))
        return result


class DevHelperApps:
    CACHE_TTL = 15

    def __init__(self, data, workspace=None, *, helper=None, runner=None, caller=None, clock=time.monotonic):
        self.data, self.workspace = Path(data), workspace
        self.helper = helper
        self.runner, self.caller, self.clock = runner, caller, clock
        self._catalogues, self._schemas = {}, {}

    def _helper(self):
        candidate = self.helper or shutil.which('helper') or str(Path.home() / '.local/bin/helper')
        if not Path(candidate).is_file() or not os.access(candidate, os.X_OK):
            raise DevHelperAppError('missing_helper', 'Install DevHelper and connect this app on this Mac.')
        return candidate

    @staticmethod
    def _app(app):
        if app not in APPS:
            raise DevHelperAppError('unsupported_app', 'This connection supports only Gmail and Figma.')
        return app

    def _run(self, arguments):
        command = [self._helper(), 'connector', *arguments, '--json']
        if self.runner:
            return self.runner(command)
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, start_new_session=True, env=_environment())
        selector = selectors.DefaultSelector()
        chunks = {process.stdout: bytearray(), process.stderr: bytearray()}
        for stream in chunks:
            selector.register(stream, selectors.EVENT_READ)
        deadline = time.monotonic() + 30
        total = 0
        try:
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise DevHelperAppError('timeout', 'DevHelper took too long to return the app metadata.')
                for key, _ in selector.select(min(.2, remaining)):
                    block = os.read(key.fileobj.fileno(), 65536)
                    if not block:
                        selector.unregister(key.fileobj)
                        continue
                    total += len(block)
                    if total > 2_000_000:
                        raise DevHelperAppError('response_too_large', 'The app metadata response was too large.')
                    chunks[key.fileobj].extend(block)
            process.wait(timeout=max(.01, deadline - time.monotonic()))
            out = bytes(chunks[process.stdout]).decode('utf-8', errors='replace')
            if process.returncode:
                raise _failure(bytes(chunks[process.stderr]).decode('utf-8', errors='replace') + out)
            return out
        except subprocess.TimeoutExpired:
            raise DevHelperAppError('timeout', 'DevHelper took too long to return the app metadata.') from None
        finally:
            _stop(process)
            selector.close()
            for stream in chunks:
                stream.close()

    def _catalogue(self, app):
        self._app(app)
        cached = self._catalogues.get(app)
        if cached and self.clock() - cached[0] < self.CACHE_TTL:
            return cached[1]
        raw = self._run([APPS[app][0]])
        if not isinstance(raw, str):
            raise DevHelperAppError('invalid_response', 'The app catalogue was unreadable.')
        text = re.sub(r'\x1b\[[0-9;]*m', '', raw)
        tools = {}
        for line in text.splitlines():
            match = re.fullmatch(r'\s{2,}([A-Za-z][A-Za-z0-9_]{0,127})\s{2,}(\S.*)', line)
            if match:
                tools[match[1]] = match[2]
        count = re.search(r'—\s*(\d+)\s+tools?:', text)
        if not count or int(count[1]) != len(tools):
            raise DevHelperAppError('invalid_response', 'The current app catalogue was incomplete or unreadable.')
        self._catalogues[app] = (self.clock(), tools)
        return tools

    def _schema(self, app, tool):
        if tool not in self._catalogue(app):
            raise DevHelperAppError('tool_not_found', 'This exact tool is not in the current app catalogue.')
        cached = self._schemas.get((app, tool))
        if cached and self.clock() - cached[0] < self.CACHE_TTL:
            return cached[1]
        raw = self._run([APPS[app][0], 'schema', tool])
        if not isinstance(raw, str):
            raise DevHelperAppError('invalid_response', 'The app input schema was unreadable.')
        try:
            schema = json.loads(raw.split('Input Schema:', 1)[-1].strip())
        except ValueError:
            raise DevHelperAppError('invalid_response', 'The app input schema was unreadable.') from None
        if not isinstance(schema, dict) or schema.get('type') != 'object':
            raise DevHelperAppError('invalid_response', 'The app did not provide an exact object input schema.')
        self._schemas[(app, tool)] = (self.clock(), schema)
        return schema

    @staticmethod
    def _name(name):
        if not isinstance(name, str):
            raise DevHelperAppError('invalid_argument', 'Choose an exact tool name returned by app search.')
        parts = name.split('__', 2)
        if len(parts) != 3 or parts[0] != 'connectors' or parts[1] not in APPS or not _IDENTIFIER.fullmatch(parts[2]):
            raise DevHelperAppError('unsupported_app', 'Choose an exact Gmail or Figma tool returned by app search.')
        return parts[1], parts[2]

    def _invoke(self, app, tool, arguments, schema):
        if self.caller:
            return self.caller(app, tool, arguments, schema)
        session = _MCPCall(self._helper(), APPS[app][0])
        try:
            return session.call(tool, arguments, schema)
        finally:
            session.close()

    @staticmethod
    def _identity(result):
        result = _unwrap_transport(result)
        if not isinstance(result, dict):
            return {}
        if isinstance(result.get('structuredContent'), dict):
            return result['structuredContent']
        for block in result.get('content', []):
            if isinstance(block, dict) and block.get('type') == 'text':
                try:
                    value = json.loads(block.get('text', ''))
                    if isinstance(value, dict):
                        return value
                except (ValueError, TypeError):
                    pass
        return result

    def status(self, app):
        self._app(app)
        base = {'id': app, 'name': APPS[app][1], 'provider': 'devhelper', 'connected': False, 'accounts': []}
        try:
            tool = 'GMAIL_GET_PROFILE' if app == 'gmail' else 'FIGMA_GET_CURRENT_USER'
            schema = self._schema(app, tool)
            self._validate({}, schema)
            result = self._invoke(app, tool, {}, schema)
            if _result_error(result):
                raise _failure(json.dumps(result, ensure_ascii=False))
            identity = self._identity(result)
            account = identity.get('emailAddress') if app == 'gmail' else identity.get('email')
            if not isinstance(account, str) or not account.strip() or '@' not in account:
                raise DevHelperAppError('invalid_response', 'The app did not return a verified account identity.')
            return dict(base, connected=True, state='connected', account=account,
                        accounts=[{'label': account, 'alias': 'devhelper', 'active': True, 'status': 'connected'}],
                        detail='Connected through DevHelper. Available actions depend on this account’s permissions.')
        except DevHelperAppError as error:
            return dict(base, state='needs_authorization' if error.code == 'needs_authorization' else 'unavailable',
                        detail=error.message, error={'code': error.code, 'message': error.message})

    def search(self, app, query):
        self._app(app)
        if not isinstance(query, str) or len(query) > 2000:
            raise DevHelperAppError('invalid_argument', 'Use a short app action search.')
        catalogue = self._catalogue(app)
        terms = re.findall(r'[\w]+', query.lower())
        ranked = sorted(catalogue, key=lambda tool: (-sum(term in (tool + ' ' + catalogue[tool]).lower() for term in terms), tool))
        return {'tools': {f'connectors__{app}__{tool}': {'description': catalogue[tool],
                         'facet': operation_kind(app, tool), 'provider': 'devhelper'} for tool in ranked}}

    def describe(self, names):
        if not isinstance(names, list) or not 1 <= len(names) <= 50 or len(names) != len(set(names)):
            raise DevHelperAppError('invalid_argument', 'Choose between one and fifty distinct exact app tool names.')
        tools, statuses = {}, {}
        for name in names:
            app, tool = self._name(name)
            schema = self._schema(app, tool)
            if app not in statuses:
                statuses[app] = self.status(app)
            tools[name] = {'description': self._catalogue(app)[tool], 'parameters': schema,
                           'facet': operation_kind(app, tool), 'provider': 'devhelper',
                           'accounts': statuses[app]['accounts']}
        return {'tools': tools}

    @staticmethod
    def _validate(arguments, schema):
        if isinstance(schema.get('properties'), dict) and set(arguments) - set(schema['properties']):
            raise DevHelperAppError('invalid_argument', 'Only parameters declared by the current app schema are supported.')
        try:
            json.dumps(arguments, ensure_ascii=False, allow_nan=False)
            # The same exact JSON Schema validator used by the Zoom bridge.
            _validate_arguments(arguments, schema)
        except (ValueError, TypeError) as error:
            if not isinstance(error, ZoomError):
                raise DevHelperAppError('invalid_argument', 'App arguments must contain only finite JSON values.') from None
            code = 'invalid_argument' if error.state == 'invalid_argument' else 'invalid_response'
            raise DevHelperAppError(code, 'Arguments do not match the current app schema. Check required fields and types.') from None

    def call(self, request):
        if not isinstance(request, dict) or set(request) - {'name', 'arguments', 'operation_id', 'expected_contract'}:
            raise DevHelperAppError('invalid_argument', 'Provide only name, arguments, expected contract and the write operation ID.')
        app, tool = self._name(request.get('name'))
        # Recheck metadata and identity at dispatch time, independent of the
        # short discovery cache. A changed schema/account invalidates approval.
        self._catalogues.pop(app, None)
        self._schemas.pop((app, tool), None)
        schema = self._schema(app, tool)
        kind = operation_kind(app, tool)
        if kind == 'unclassified':
            raise DevHelperAppError('unclassified', 'This newly discovered tool has not been classified and cannot be executed.')
        arguments = request.get('arguments')
        if not isinstance(arguments, dict):
            raise DevHelperAppError('invalid_argument', 'App arguments must be an object.')
        self._validate(arguments, schema)
        if kind == 'write' and (not isinstance(request.get('operation_id'), str)
                               or not 8 <= len(request['operation_id']) <= 128):
            raise DevHelperAppError('invalid_argument', 'A stable operation ID is required for an approved app change.')
        status = self.status(app)
        if not status['connected']:
            raise DevHelperAppError(status.get('error', {}).get('code', 'needs_authorization'), status['detail'])
        contract = {'description': self._catalogue(app)[tool], 'parameters': schema,
                    'facet': kind, 'provider': 'devhelper', 'accounts': status['accounts']}
        expected = request.get('expected_contract')
        if expected is not None and expected != contract:
            code = 'account_changed' if isinstance(expected, dict) and expected.get('accounts') != contract['accounts'] else 'schema_changed'
            raise DevHelperAppError(code, 'The app account or tool changed after approval. Check it before trying again.')
        result = self._invoke(app, tool, arguments, schema)
        if _result_error(result):
            raise _failure(json.dumps(result, ensure_ascii=False))
        return {'result': _sanitize(result), 'provider': 'devhelper', 'submitted': kind == 'write', 'verified': False}
