"""Pico's audited bridge to the user's separately authenticated DevHelper.

No credentials are imported, copied, or persisted here. DevHelper performs its own
SSO and Zoom permission checks for every request. The exact read allowlist below
is deliberately independent of gateway descriptions and readOnlyHint metadata.
"""
import datetime
from collections import OrderedDict
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid


from zoom_operations import READ_TOOLS, WRITE_TOOLS, DOCUMENT_WRITE_TOOLS, operation_kind

SERVICE_NAMES = {
    'meeting': 'Meetings', 'contact': 'Contacts', 'docs': 'Docs & Canvas',
    'team_chat': 'Team Chat', 'calendar': 'Calendar', 'recording': 'Recordings',
    'mail': 'Mail', 'sheet': 'Sheets', 'sheets': 'Sheets', 'whiteboard': 'Whiteboards',
    'task': 'Tasks', 'tasks': 'Tasks', 'clip': 'Clips', 'clips': 'Clips',
    'phone': 'Phone', 'webinar': 'Webinars', 'workspace': 'Workspace',
    'accelerator': 'Revenue Accelerator', 'docs_data_table': 'Docs Data Tables',
}

_IDENTIFIER = re.compile(r'^[A-Za-z][A-Za-z0-9_]{0,127}$')
_SECRET_KEYS = re.compile(r'^(access_?token|refresh_?token|id_?token|authorization|api_?key|client_?secret|password)$', re.I)
_PAGINATION_KEYS = {'next_page_token', 'nextPageToken', 'next_cursor', 'nextCursor',
                    'page_token', 'pageToken', 'has_more', 'hasMore', 'total', 'total_records'}


class ZoomError(ValueError):
    def __init__(self, state, message):
        super().__init__(message)
        self.state = state


def _sanitize(value):
    if isinstance(value, dict):
        return {key: '[redacted]' if _SECRET_KEYS.fullmatch(str(key)) else _sanitize(item)
                for key, item in value.items()}
    if isinstance(value, list):
        return [_sanitize(item) for item in value]
    if isinstance(value, str):
        if value.lstrip().startswith(('{', '[')):
            try:
                embedded = json.loads(value)
            except ValueError:
                pass
            else:
                return json.dumps(_sanitize(embedded), ensure_ascii=False)
        value = re.sub(r'(?i)Bearer\s+[A-Za-z0-9._~+/-]+=*', 'Bearer [redacted]', value)
        value = re.sub(r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '[redacted]', value)
        value = re.sub(r'\bsk-[A-Za-z0-9_-]{12,}', '[redacted]', value)
        value = re.sub(r'(?i)([?&](?:access_token|refresh_token|api_key|client_secret)=)[^&\s]+', r'\1[redacted]', value)
    return value


def _failure(text):
    """Classify a failed CLI/API result without returning its diagnostic payload."""
    value = str(text).lower()
    if any(word in value for word in ('401', 'unauthorized', 'unauthenticated', 'not logged',
                                      'not authenticated', 'expired token', 'token expired', 'login required', 'invalid access token')):
        return ZoomError('needs_login', 'Zoom sign-in has expired or is unavailable. Sign in to DevHelper, then reconnect in Pico settings.')
    if any(word in value for word in ('403', 'forbidden', 'permission denied', 'insufficient scope', 'access denied', 'access permission denied')):
        return ZoomError('permission_denied', 'Your Zoom account or administrator has not granted access to this information. Other connected Zoom services may still work.')
    return ZoomError('unavailable', 'Zoom could not complete this request. No successful result was returned. Try again later or check DevHelper sign-in.')


def _json_output(text, schema=False):
    """Some helper versions ignore --json for tables and schema descriptions."""
    text = re.sub(r'\x1b\[[0-9;]*m', '', text).strip()
    if schema and 'Input Schema:' in text:
        text = text.split('Input Schema:', 1)[1].strip()
    try:
        parsed = json.loads(text)
    except (ValueError, TypeError):
        classified = _failure(text)
        if classified.state in ('needs_login', 'permission_denied'):
            raise classified from None
        raise ZoomError('invalid_response', 'DevHelper returned an unreadable response. Update DevHelper and reconnect; no result has been verified.') from None
    if _result_error(parsed):
        raise _failure(json.dumps(parsed, ensure_ascii=False))
    return parsed


def _result_error(value):
    if not isinstance(value, dict):
        return False
    if value.get('isError') is True or value.get('success') is False or value.get('status') is False or value.get('error'):
        return True
    if value.get('errorCode') or value.get('error_code'):
        return True
    if isinstance(value.get('code'), int) and value['code'] not in (0, 200) and value.get('message'):
        return True
    code = value.get('status_code', value.get('statusCode', value.get('http_status')))
    if isinstance(code, int) and code >= 400:
        return True
    # MCP transports often embed the service's JSON failure inside a text block.
    for content in value.get('content', []) if isinstance(value.get('content'), list) else []:
        if isinstance(content, dict) and content.get('type') == 'text':
            try:
                if _result_error(json.loads(content.get('text', ''))):
                    return True
            except (ValueError, TypeError):
                pass
    return False


def _validate_arguments(value, schema):
    """Validate the discovered contract without requiring a new runtime package."""
    try:
        import jsonschema
    except ImportError:
        jsonschema = None
    if jsonschema:
        try:
            jsonschema.validate(value, schema)
        except jsonschema.ValidationError as error:
            where = '.'.join(str(part) for part in error.absolute_path) or 'arguments'
            raise ZoomError('invalid_argument', 'Zoom arguments do not match zoom_schema at ' + where + '. Check the discovered parameter types and required fields.') from None
        except jsonschema.SchemaError:
            raise ZoomError('invalid_response', 'The Zoom gateway returned an invalid input schema; this tool was not called.') from None
        return

    def check(item, rule, path='arguments'):
        for alternative in ('anyOf', 'oneOf'):
            if alternative in rule:
                matches = 0
                for branch in rule[alternative]:
                    try:
                        check(item, branch, path)
                        matches += 1
                    except ZoomError:
                        pass
                if not matches or (alternative == 'oneOf' and matches != 1):
                    raise ZoomError('invalid_argument', 'Zoom arguments do not match zoom_schema at ' + path + '.')
        kind = rule.get('type')
        types = kind if isinstance(kind, list) else [kind] if kind else []
        matches = {'object': isinstance(item, dict), 'array': isinstance(item, list),
                   'string': isinstance(item, str), 'integer': type(item) is int,
                   'number': type(item) in (int, float), 'boolean': type(item) is bool,
                   'null': item is None}
        if types and not any(matches.get(name, False) for name in types):
            raise ZoomError('invalid_argument', 'Zoom argument has the wrong type at ' + path + '.')
        if 'enum' in rule and item not in rule['enum']:
            raise ZoomError('invalid_argument', 'Zoom argument is not an allowed value at ' + path + '.')
        if isinstance(item, dict):
            if any(name not in item for name in rule.get('required', [])):
                raise ZoomError('invalid_argument', 'Zoom arguments are missing a required field at ' + path + '.')
            properties = rule.get('properties', {})
            for name, child in item.items():
                if name in properties:
                    check(child, properties[name], path + '.' + name)
                elif rule.get('additionalProperties') is False:
                    raise ZoomError('invalid_argument', 'Unexpected Zoom argument at ' + path + '.' + name + '.')
                elif isinstance(rule.get('additionalProperties'), dict):
                    check(child, rule['additionalProperties'], path + '.' + name)
        elif isinstance(item, list):
            if len(item) < rule.get('minItems', 0) or len(item) > rule.get('maxItems', float('inf')):
                raise ZoomError('invalid_argument', 'Zoom array size does not match zoom_schema at ' + path + '.')
            for child in item:
                check(child, rule.get('items', {}), path + '[]')
        elif isinstance(item, str):
            if len(item) < rule.get('minLength', 0) or len(item) > rule.get('maxLength', float('inf')):
                raise ZoomError('invalid_argument', 'Zoom text length does not match zoom_schema at ' + path + '.')
        elif type(item) in (int, float):
            if item < rule.get('minimum', -float('inf')) or item > rule.get('maximum', float('inf')):
                raise ZoomError('invalid_argument', 'Zoom number is outside zoom_schema bounds at ' + path + '.')
    check(value, schema)


class ZoomConnector:
    SETTINGS_FILE = 'zoom-connection.json'
    COMMAND_TIMEOUT = 25
    OUTPUT_LIMIT = 2_000_000
    RESULT_LIMIT = 24_000

    def __init__(self, data, *, runner=None, helper=None, gate=None, workspace=None):
        self.data = Path(data)
        self.workspace = Path(workspace) if workspace is not None else None
        self.path = self.data / self.SETTINGS_FILE
        self.runner = runner
        self.helper = helper
        self.gate = gate
        self._schemas = {}
        self._catalog = {}
        self._read_cache = OrderedDict()
        self._cache_generation = None

    def _settings(self):
        try:
            value = json.loads(self.path.read_text())
            return value if isinstance(value, dict) else {}
        except (OSError, ValueError):
            return {}

    def _save(self, value):
        self.data.mkdir(parents=True, exist_ok=True)
        fd, temp = tempfile.mkstemp(prefix='.zoom-connection-', dir=self.data)
        try:
            with os.fdopen(fd, 'w') as stream:
                os.fchmod(stream.fileno(), 0o600)
                json.dump(value, stream, ensure_ascii=False)
            os.replace(temp, self.path)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)

    def _remember_error(self, error):
        if error.state not in {'needs_login', 'permission_denied', 'unavailable', 'missing_helper', 'timeout'}:
            return
        settings = self._settings()
        settings.update(last_error_state=error.state, last_error_message=str(error),
                        last_error_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
        self._save(settings)

    def _verified(self, service, *, read=True):
        settings = self._settings()
        for key in ('last_error_state', 'last_error_message', 'last_error_at'):
            settings.pop(key, None)
        settings['verified_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        for item in settings.get('services', []):
            if item.get('id') == service:
                if read:
                    item['verified'] = True
                else:
                    item['write_committed'] = True
        self._save(settings)

    def _helper(self):
        candidate = self.helper or shutil.which('helper') or str(Path.home() / '.local/bin/helper')
        if not Path(candidate).is_file() or not os.access(candidate, os.X_OK):
            raise ZoomError('missing_helper', 'Install DevHelper and sign in with your Zoom account to connect Zoom to Pico on this Mac.')
        return candidate

    def _require_enabled(self):
        settings = self._settings()
        generation = settings.get('connection_id')
        if settings.get('enabled') is not True or generation != self._cache_generation:
            self._read_cache.clear()
            self._cache_generation = generation
        if settings.get('enabled') is not True:
            raise ZoomError('disconnected', 'Zoom is not connected to Pico. Connect it in Pico settings first.')

    def _command(self, arguments):
        return self._run_command([self._helper(), 'zoom', *arguments, '--json'])

    def _local_command(self, tool, arguments):
        if tool not in {'zoom_chat_send_file', 'zoom_chat_download_file'}:
            raise ZoomError('tool_unavailable', 'This local Zoom file operation is not available.')
        if not isinstance(arguments, dict):
            raise ZoomError('invalid_argument', 'Zoom file arguments must be an object.')
        return self._run_command([self._helper(), 'tool', 'run', tool, '--args-json',
                                  json.dumps(arguments, ensure_ascii=False), '--json'])

    def _run_command(self, command):
        if self.runner:
            return self.runner(command)
        env = dict(os.environ, NO_COLOR='1', CI='1')
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True, env=env)
        chunks = {process.stdout: bytearray(), process.stderr: bytearray()}
        selector = selectors.DefaultSelector()
        for pipe in chunks:
            selector.register(pipe, selectors.EVENT_READ)
        deadline = time.monotonic() + self.COMMAND_TIMEOUT
        size = 0
        try:
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ZoomError('timeout', 'Zoom took too long to respond. The request was stopped; no result has been verified.')
                for key, _ in selector.select(min(remaining, 0.2)):
                    block = os.read(key.fileobj.fileno(), 65536)
                    if not block:
                        selector.unregister(key.fileobj)
                        continue
                    size += len(block)
                    if size > self.OUTPUT_LIMIT:
                        raise ZoomError('response_too_large', 'Zoom returned too much information. Retry with a narrower date range or a smaller page size.')
                    chunks[key.fileobj].extend(block)
            try:
                process.wait(timeout=max(0.01, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                raise ZoomError('timeout', 'Zoom took too long to respond. The request was stopped; no result has been verified.') from None
            out = bytes(chunks[process.stdout]).decode('utf-8', errors='replace')
            err = bytes(chunks[process.stderr]).decode('utf-8', errors='replace')
            if process.returncode:
                if not out.strip() and re.fullmatch(r'\s*(?:Error:\s*)?Gateway returned no text content\s*\[trackingId=[A-Za-z0-9_-]+\]\s*', err):
                    raise ZoomError('empty_response', 'The Zoom gateway returned no response body. The operation outcome is not yet confirmed.')
                raise _failure(err + '\n' + out)
            return out
        except BaseException:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except PermissionError:
                    # A very short-lived macOS script may have exited between
                    # poll() and killpg(). Reap it without replacing the actual
                    # request error; if it remains live, stop the direct child.
                    if process.poll() is None:
                        try:
                            process.kill()
                        except ProcessLookupError:
                            pass
                process.wait()
            raise
        finally:
            selector.close()
            for pipe in chunks:
                pipe.close()

    @staticmethod
    def _identifier(value):
        if not isinstance(value, str) or not _IDENTIFIER.fullmatch(value):
            raise ZoomError('invalid_argument', 'Use an exact Zoom service and tool name from zoom_discover.')
        return value

    def _allowed(self, service, tool):
        service, tool = self._identifier(service), self._identifier(tool)
        if tool not in READ_TOOLS.get(service, ()):
            raise ZoomError('read_only', 'This operation is not a permitted Zoom read. Use zoom_write for an exact listed write tool and the current requested action.')
        return service, tool

    def _service_tools(self, service):
        service = self._identifier(service)
        if service not in READ_TOOLS:
            return []
        if service not in self._catalog:
            text = self._command([service])
            try:
                value = json.loads(text)
            except ValueError:
                # Exact indented first-column identifiers from helper's tool table.
                names = re.findall(r'^[ \t]{2,}([A-Za-z][A-Za-z0-9_]+)[ \t]+', text, re.M)
            else:
                tools = value.get('tools', []) if isinstance(value, dict) else value
                names = [item.get('name', '') if isinstance(item, dict) else item
                         for item in tools] if isinstance(tools, list) else []
            allowed = READ_TOOLS[service] | WRITE_TOOLS.get(service, frozenset())
            self._catalog[service] = [name for name in names if name in allowed]
        return self._catalog[service]

    def _schema(self, service, tool):
        key = (service, tool)
        if key not in self._schemas:
            if tool not in self._service_tools(service):
                raise ZoomError('tool_unavailable', 'This audited tool is not available from the connected Zoom gateway.')
            raw = self._command([service, 'schema', tool])
            parsed = _json_output(raw, schema=True)
            schema = parsed.get('inputSchema', parsed) if isinstance(parsed, dict) else None
            if not isinstance(schema, dict) or schema.get('type') != 'object':
                raise ZoomError('invalid_response', 'Zoom did not provide a valid input schema for this tool. The tool was not called.')
            description = ''
            if 'Description:' in raw and 'Input Schema:' in raw:
                description = raw.split('Description:', 1)[1].split('Input Schema:', 1)[0].strip()
            elif isinstance(parsed, dict):
                description = str(parsed.get('description', ''))
            metadata = {'service': service, 'tool': tool, 'description': description[:18000],
                        'inputSchema': schema, 'operation': 'write' if tool in WRITE_TOOLS.get(service, ()) else 'read',
                        'untrusted': True}
            if service == 'sheets' and tool in ('sheets_edit_cells', 'sheets_create_spreadsheet'):
                # The gateway emits protobuf Value as an empty object even at
                # paths whose own documented contract restricts cells to scalar
                # literals or formula strings. No other object schema is relaxed.
                prefix = ('properties', 'sheets', 'items') if tool == 'sheets_create_spreadsheet' else ()
                paths = [(prefix + ('properties', 'cellValues', 'items', 'properties', 'values'), 'literal'),
                         (prefix + ('properties', 'cellFormulas', 'items', 'properties', 'formulas'), 'formula')]
                if tool == 'sheets_edit_cells':
                    paths.append((('properties', 'appendRows', 'properties', 'values'), 'literal'))
                normalized = json.loads(json.dumps(schema))
                corrected_paths = []
                for path, kind in paths:
                    try:
                        container, corrected_container = schema, normalized
                        for part in path:
                            container, corrected_container = container[part], corrected_container[part]
                        cell = container['items']['items']
                        corrected = corrected_container['items']['items']
                        documented = str(container.get('description', '')).lower() + ' ' + str(cell.get('description', '')).lower()
                        explicit = (all(word in documented for word in ('string', 'number', 'null'))
                                    and ('bool' in documented)) if kind == 'literal' else ('string' in documented and '=' in documented and 'formula' in documented)
                        if (explicit and cell.get('type') == 'object' and cell.get('properties') == {}
                                and set(cell) <= {'type', 'properties', 'description'}):
                            corrected.pop('properties', None)
                            corrected['type'] = ['string', 'number', 'boolean', 'null'] if kind == 'literal' else 'string'
                            if kind == 'formula':
                                corrected['pattern'] = '^='
                            corrected_paths.append('.'.join(path + ('items', 'items')))
                    except (KeyError, TypeError):
                        continue
                if corrected_paths:
                    metadata.update(raw_input_schema=schema, inputSchema=normalized,
                                    compatibility_note='Only the documented literal scalar/formula string cells at ' + ', '.join(corrected_paths) + ' are normalized from the gateway empty-object protobuf Value schema. Formula strings must begin with =. The raw schema is preserved. Other fields retain their discovered validation; gateway execution can still reject a request.')
            if service == 'team_chat' and tool == 'team_chat_session_metadata_fetch':
                field = schema.get('properties', {}).get('chat_session_id', {})
                description_text = str(field.get('description', '')).lower()
                if (field.get('type') == 'object' and field.get('properties') == {}
                        and set(field) <= {'type', 'properties', 'description'}
                        and all(phrase in description_text for phrase in ('single string', 'array', '10 strings'))):
                    normalized = json.loads(json.dumps(schema))
                    normalized['properties']['chat_session_id'] = {'description': field.get('description', ''),
                        'oneOf': [{'type': 'string', 'minLength': 1},
                                  {'type': 'array', 'minItems': 1, 'maxItems': 10,
                                   'items': {'type': 'string', 'minLength': 1}}]}
                    metadata.update(raw_input_schema=schema, inputSchema=normalized,
                                    compatibility_note='Only team_chat_session_metadata_fetch.chat_session_id is corrected from the gateway empty-object schema to its documented single string or array of 1–10 strings. The raw schema is preserved; no other read field is relaxed.')
            self._schemas[key] = metadata
        return self._schemas[key]

    def status(self, args=None):
        settings = self._settings()
        enabled = settings.get('enabled') is True
        state = 'connected' if enabled and settings.get('verified_at') else 'disconnected'
        message = ('Connected through DevHelper on this Mac. Zoom checks your permissions on every request.'
                   if state == 'connected' else 'Connect your Zoom account through DevHelper on this Mac.')
        if settings.get('last_error_state'):
            state = settings['last_error_state']
            message = settings.get('last_error_message', message)
        try:
            self._helper()
        except ZoomError as error:
            state, message = error.state, str(error)
        services = []
        stored = {item.get('id'): item for item in settings.get('services', []) if isinstance(item, dict)}
        for service in READ_TOOLS:
            item = dict(stored.get(service, {'id': service, 'name': SERVICE_NAMES.get(service, service),
                                              'available': False, 'verified': False}))
            item.update(read_tool_count=len(READ_TOOLS[service]), write_tool_count=len(WRITE_TOOLS.get(service, ())))
            services.append(item)
        return {'enabled': enabled, 'state': state, 'message': message,
                'verified_at': settings.get('verified_at'), 'verification': 'last_successful_request' if settings.get('verified_at') else 'not_verified',
                'services': services, 'read_only': False,
                'write_services': [key for key, tools in WRITE_TOOLS.items() if tools],
                'write_permission_verified': False,
                'write_capabilities': ['Exact catalogued Zoom changes, subject to the current user request and Zoom permissions']}

    def connect(self):
        """One harmless authenticated read; cached metadata alone is not proof."""
        try:
            metadata = _json_output(self._command([]))
            if not isinstance(metadata, list):
                raise ZoomError('invalid_response', 'DevHelper did not return a Zoom service catalog. No account connection was verified.')
            available = {item.get('name') for item in metadata if isinstance(item, dict)}
            self._schema('contact', 'contacts_group_query')
            result = _json_output(self._command(['contact', 'contacts_group_query', '--args-json', '{}']))
            if _result_error(result):
                raise _failure(json.dumps(result, ensure_ascii=False))
            services = [{'id': service, 'name': SERVICE_NAMES.get(service, service.replace('_', ' ').title()),
                         'available': service in available, 'verified': service == 'contact',
                         'availability': 'gateway_catalog' if service in available else 'not_in_gateway_catalog'}
                        for service in READ_TOOLS]
            self._save({'enabled': True, 'connection_id': str(uuid.uuid4()),
                        'verified_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                        'services': services, 'verification_tool': 'contacts_group_query'})
            return self.status()
        except ZoomError as error:
            self._remember_error(error)
            result = self.status()
            result.update(state=error.state, message=str(error))
            return result

    def disconnect(self):
        settings = self._settings()
        settings['enabled'] = False
        for key in ('last_error_state', 'last_error_message', 'last_error_at'):
            settings.pop(key, None)
        self._save(settings)
        self._schemas.clear()
        self._catalog.clear()
        self._read_cache.clear()
        return self.status()

    def catalog(self, args=None):
        self._require_enabled()
        args = args or {}
        service = args.get('service')
        if not service:
            availability = {item['id']: item.get('available', False)
                            for item in self._settings().get('services', []) if isinstance(item, dict) and 'id' in item}
            return {'services': [{'id': key, 'name': SERVICE_NAMES.get(key, key.title()),
                                  'read_tool_count': len(value), 'write_tool_count': len(WRITE_TOOLS.get(key, ())),
                                  'gateway_available': availability.get(key, False),
                                  'permission_verified': False} for key, value in READ_TOOLS.items()],
                    'read_only': False, 'next_step': 'Choose a service, then call zoom_discover with its exact id. Inspect zoom_schema before zoom_read or zoom_write. Read and write tools are classified explicitly; Zoom checks each operation and resource permission.'}
        service = self._identifier(service)
        self._require_enabled()
        tools = self._service_tools(service)
        return {'service': service, 'tools': tools,
                'read_tools': [tool for tool in tools if tool in READ_TOOLS.get(service, ())],
                'write_tools': [tool for tool in tools if tool in WRITE_TOOLS.get(service, ())],
                'read_only': not bool(WRITE_TOOLS.get(service)),
                'next_step': 'Call zoom_schema with the exact service and tool before choosing arguments. Use zoom_read for listed read tools and zoom_write for listed write tools; command/query arguments are checked locally.'}

    def schema(self, args):
        self._require_enabled()
        service, tool = self._identifier(args.get('service')), self._identifier(args.get('tool'))
        if tool not in READ_TOOLS.get(service, ()) and tool not in WRITE_TOOLS.get(service, ()):
            raise ZoomError('read_only', 'This operation is outside Pico\'s audited Zoom tools.')
        result = self._schema(service, tool)
        self._require_enabled()
        return result

    def write(self, args):
        if args.get('service') == 'docs' and args.get('tool') in DOCUMENT_WRITE_TOOLS:
            from zoom_documents import ZoomDocumentWriter
            return ZoomDocumentWriter(self).write(args)
        from zoom_writes import ZoomGenericWriter
        return ZoomGenericWriter(self).write(args)

    def read(self, args):
        try:
            return self._read(args)
        except ZoomError as error:
            self._remember_error(error)
            raise

    def _read(self, args):
        self._require_enabled()
        service, tool = self._allowed(args.get('service'), args.get('tool'))
        arguments = args.get('arguments', {})
        if not isinstance(arguments, dict):
            raise ZoomError('invalid_argument', 'Zoom tool arguments must be a JSON object matching zoom_schema.')
        encoded = json.dumps(arguments, ensure_ascii=False, sort_keys=True)
        if len(encoded.encode()) > 48000:
            raise ZoomError('invalid_argument', 'Zoom arguments are too large; use a shorter query.')
        offset = args.get('output_offset', 0)
        if type(offset) is not int or offset < 0:
            raise ZoomError('invalid_argument', 'output_offset must be a nonnegative integer returned by a previous Zoom read.')
        cache_key = (service, tool, encoded)
        if offset:
            if cache_key not in self._read_cache:
                raise ZoomError('cache_expired', 'This Zoom result is no longer in memory. Repeat the same read with output_offset 0 before continuing.')
            text, pagination = self._read_cache[cache_key]
            self._read_cache.move_to_end(cache_key)
            return self._excerpt(service, tool, text, pagination, offset)
        metadata = self._schema(service, tool)
        required = metadata['inputSchema'].get('required', [])
        missing = [name for name in required if name not in arguments]
        if missing:
            raise ZoomError('invalid_argument', 'Missing required Zoom arguments: ' + ', '.join(missing))
        _validate_arguments(arguments, metadata['inputSchema'])
        if any(key not in metadata['inputSchema'].get('properties', {}) for key in arguments):
            raise ZoomError('invalid_argument', 'Only exact parameters from the current Zoom schema are allowed.')
        if operation_kind(service, tool, arguments) != 'read':
            raise ZoomError('read_only', 'This query does not meet the local read-only argument policy. No request was sent.')
        self._require_enabled()
        connection = self._settings().get('connection_id')
        result = _json_output(self._command([service, tool, '--args-json', encoded]))
        self._require_enabled()
        if self._settings().get('connection_id') != connection:
            raise ZoomError('disconnected', 'The Zoom connection changed while reading. Repeat the read in the current connection.')
        if _result_error(result):
            raise _failure(json.dumps(result, ensure_ascii=False))
        self._verified(service)
        result = _sanitize(result)
        text = json.dumps(result, ensure_ascii=False)
        pagination = {}
        def cursors(value, depth=0):
            if depth > 5:
                return
            if isinstance(value, str) and value.lstrip().startswith(('{', '[')):
                try:
                    value = json.loads(value)
                except ValueError:
                    return
            if isinstance(value, list):
                for item in value[:10]:
                    cursors(item, depth+1)
            if isinstance(value, dict):
                for key, item in value.items():
                    if key in _PAGINATION_KEYS:
                        pagination[key] = item
                    elif isinstance(item, (dict, list, str)):
                        cursors(item, depth+1)
        cursors(result)
        self._read_cache[cache_key] = (text, pagination)
        self._read_cache.move_to_end(cache_key)
        while len(self._read_cache) > 4:
            self._read_cache.popitem(last=False)
        if len(text) > self.RESULT_LIMIT:
            return self._excerpt(service, tool, text, pagination, 0)
        return {'service': service, 'tool': tool, 'result': result, 'truncated': False, 'untrusted': True}

    def _excerpt(self, service, tool, text, pagination, offset):
        if offset >= len(text):
            raise ZoomError('invalid_argument', 'output_offset is past the end of the cached Zoom result.')
        end = min(offset + self.RESULT_LIMIT, len(text))
        return {'service': service, 'tool': tool, 'truncated': True, 'untrusted': True,
                'pagination': pagination, 'content_excerpt': text[offset:end],
                'output_offset': offset, 'next_output_offset': end if end < len(text) else None,
                'total_characters': len(text), 'output_complete': end == len(text),
                'notice': 'This is one chunk of a cached Zoom response. Continue with next_output_offset and identical arguments to read the remainder without a new request. Server pagination remains separate; do not claim complete coverage until both are read.'}


def main():
    # NSProcess.terminate sends SIGTERM; raising SystemExit lets _command clean up
    # its own helper process group rather than leaving an orphan request behind.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    action = sys.argv[1] if len(sys.argv) == 2 else 'invalid'
    data = Path(os.environ.get('TELOS_DATA_DIR', str(Path.home() / 'Library/Application Support/Telos')))
    connector = ZoomConnector(data)
    try:
        if action not in {'status', 'connect', 'disconnect'}:
            raise ZoomError('invalid_argument', 'Use status, connect or disconnect.')
        result = getattr(connector, action)()
    except ZoomError as error:
        result = {'enabled': False, 'state': error.state, 'message': str(error), 'services': [], 'read_only': True}
    except Exception:
        result = {'enabled': False, 'state': 'unavailable', 'message': 'Pico could not read the Zoom connection settings. Try reconnecting.', 'services': [], 'read_only': True}
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
