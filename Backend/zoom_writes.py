"""Single-submit Zoom mutations with exact authorization and honest readback.

The static registry is not a permission grant. DevHelper supplies the current
schema and enforces the signed-in user's scope for every actual operation.
"""
import hashlib
import json
import re

from zoom_connector import (ZoomError, _failure, _json_output, _result_error,
                            _sanitize, _validate_arguments)
from zoom_documents import OperationJournal, encoded
from zoom_operations import DOCUMENT_WRITE_TOOLS, operation_effects, operation_kind


_MISSING = object()
_TASK_UPDATE_FIELDS = frozenset(('title', 'description', 'status', 'priority', 'due_date', 'is_public', 'starred'))
_ID_KEYS = ('id', 'message_id', 'messageId', 'messageID', 'event_id', 'eventId',
            'meetingId', 'meeting_id', 'meeting_uuid', 'taskId', 'task_id',
            'file_id', 'fileId', 'sheetId', 'worksheetId', 'docId', 'clip_id',
            'recording_id', 'table_id', 'channel_id', 'session_id', 'chat_session_id',
            'draft_id', 'draftId', 'reservation_id', 'reservationId', 'user_id')
_STATUS_KEYS = ('success', 'status', 'code', 'statusCode', 'status_code',
                'errorCode', 'error_code', 'file_link', 'url', 'link')
_FAMILIES = {
    'team_chat': [('chat_session_id', 'session_id', 'channel_id', 'channelId'),
                  ('message_id', 'messageId', 'messageID', 'id')],
    'mail': [('message_id', 'messageId', 'messageID', 'id'), ('email', 'mailbox')],
    'calendar': [('cal_id', 'calendarId', 'calendar_id'), ('event_id', 'eventId', 'id')],
    'meeting': [('meetingId', 'meeting_id', 'meeting_uuid', 'id'), ('occurrence_id',)],
    'tasks': [('taskId', 'task_id', 'id')],
    'sheets': [('sheetId', 'sheet_id', 'file_id', 'fileId', 'id'), ('worksheetId', 'worksheet_id')],
    'docs': [('file_id', 'fileId', 'id'), ('table_id',)],
    'docs_data_table': [('file_id', 'fileId', 'id'), ('table_id',)],
    'whiteboard': [('docId', 'doc_id', 'id')],
    'clips': [('clip_id', 'clipId', 'id')],
    'recording': [('recording_id', 'recordingId', 'id')],
    'workspace': [('reservation_id', 'reservationId', 'id'), ('workspace_id', 'workspaceId')],
}


def _layers(value):
    """Decode service and MCP envelopes, retaining acknowledgement metadata."""
    result = []
    for _ in range(12):
        if isinstance(value, str):
            try:
                value = json.loads(value)
            except ValueError:
                result.append(value)
                break
        result.append(value)
        if not isinstance(value, dict):
            break
        content = value.get('content')
        if isinstance(content, list):
            texts = [item.get('text') for item in content if isinstance(item, dict) and item.get('type') == 'text']
            if len(texts) == 1:
                value = texts[0]
                continue
        key = next((key for key in ('data', 'result') if key in value and isinstance(value[key], (dict, list, str, bool))), None)
        if key is None:
            break
        value = value[key]
    return result


def _payload(value):
    return _layers(value)[-1]


def _objects(value, depth=0):
    if depth > 8:
        return
    if isinstance(value, str) and value.lstrip().startswith(('{', '[')):
        try:
            value = json.loads(value)
        except ValueError:
            return
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from _objects(child, depth + 1)
    elif isinstance(value, list):
        for child in value[:500]:
            yield from _objects(child, depth + 1)


def _lookup(value, path):
    for part in path.split('.'):
        if isinstance(value, str) and value.lstrip().startswith(('{', '[')):
            try:
                value = json.loads(value)
            except ValueError:
                return _MISSING
        if isinstance(value, dict):
            value = value.get(part, _MISSING)
        elif isinstance(value, list) and part.isdecimal() and int(part) < len(value):
            value = value[int(part)]
        else:
            return _MISSING
    return value


def _scalars(value):
    if isinstance(value, dict):
        for child in value.values():
            yield from _scalars(child)
    elif isinstance(value, list):
        for child in value:
            yield from _scalars(child)
    else:
        yield value


def _same(left, right):
    if type(left) is not type(right):
        return False
    if isinstance(left, list):
        return len(left) == len(right) and all(_same(a, b) for a, b in zip(left, right))
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(_same(left[key], right[key]) for key in left)
    return left == right


def _find(value, keys):
    for obj in _objects(value):
        for key in keys:
            item = obj.get(key)
            if isinstance(item, (str, int)) and not isinstance(item, bool) and str(item).strip():
                return item
    return None


def _summary(value):
    # Retry storage retains IDs/acknowledgements, not echoed mail/chat/Doc bodies.
    summaries = []
    for obj in _objects(value):
        item = {key: child for key, child in obj.items()
                if key in _ID_KEYS + _STATUS_KEYS and isinstance(child, (str, int, bool, type(None)))
                and (not isinstance(child, str) or len(child) <= 2000)}
        if item and item not in summaries:
            summaries.append(item)
        if len(summaries) >= 12:
            break
    if len(summaries) == 1:
        return summaries[0]
    return {'acknowledgements': summaries} if summaries else {}


def _acknowledged(value, tool):
    if _has_failure(value):
        return False
    for layer in _layers(value):
        if layer is True:
            return True
        if not isinstance(layer, dict):
            continue
        if (layer.get('success') is True or layer.get('status') is True
                or layer.get('status') in ('success', 'ok', 'OK', 'succeeded', 'completed')
                or type(layer.get('code')) is int and layer['code'] in (0, 200)
                or type(layer.get('statusCode')) is int and 200 <= layer['statusCode'] < 300
                or type(layer.get('status_code')) is int and 200 <= layer['status_code'] < 300
                or type(layer.get('errorCode')) is int and layer['errorCode'] == 0):
            return True
    if tool == 'sheets_edit_cells':
        payload = _payload(value)
        if (isinstance(payload, dict) and type(payload.get('affectedCells')) is int
                and payload['affectedCells'] >= 0 and type(payload.get('version')) is int
                and payload['version'] >= 0 and isinstance(payload.get('affectedRanges'), list)
                and all(isinstance(item, str) and item for item in payload['affectedRanges'])):
            return True
    # Services returning a newly assigned resource ID omit a separate success flag.
    if any(word in tool for word in ('create', 'send', 'insert', 'add_worksheet', 'reply')):
        return _find(_payload(value), _ID_KEYS) is not None
    return False


def _has_failure(value):
    for layer in _layers(value):
        if layer is False:
            return True
        if _result_error(layer):
            return True
        if isinstance(layer, dict) and str(layer.get('status', '')).lower() in ('error', 'failed', 'failure'):
            return True
    return False


class ZoomGenericWriter:
    def __init__(self, connector):
        self.zoom = connector

    def _check(self, generation, connection):
        self.zoom._require_enabled()
        if self.zoom._settings().get('connection_id') != connection:
            raise ZoomError('disconnected', 'The Zoom connection changed before submission. Nothing was sent.')
        gate = self.zoom.gate
        if hasattr(gate, 'check_execution'):
            gate.check_execution(generation)
        elif generation is not None and getattr(gate, 'generation', None) != generation:
            raise ZoomError('superseded', 'A newer request replaced this change. Nothing was sent.')

    @staticmethod
    def _previous(journal, operation, fingerprint, connection):
        try:
            return journal.existing(operation, fingerprint, connection)
        except ZoomError as error:
            if error.state == 'outcome_unknown':
                raise ZoomError('outcome_unknown', 'The previous change may have reached Zoom. Inspect the actual message, event, file or other resource before retrying; do not change operation_id to resend.') from None
            raise

    @staticmethod
    def _claim(journal, operation, fingerprint, connection):
        # Both ID- and intent-level uncertainty checks belong to the same
        # transaction, including callers in another process.
        journal.db.execute('BEGIN IMMEDIATE')
        try:
            previous = ZoomGenericWriter._previous(journal, operation, fingerprint, connection)
            if previous is None:
                duplicate = journal.db.execute("SELECT id FROM operations WHERE fingerprint=? AND connection=? AND state IN ('in_flight','outcome_unknown') LIMIT 1", (fingerprint, connection)).fetchone()
                if duplicate:
                    raise ZoomError('outcome_unknown', 'An identical change may already have reached Zoom. Inspect its actual state before retrying.')
                import time
                journal.db.execute('INSERT INTO operations VALUES (?,?,?,?,?,?)', (operation, fingerprint, connection, 'in_flight', None, time.time()))
            journal.db.commit()
            return previous
        except BaseException:
            journal.db.rollback()
            raise

    @staticmethod
    def _resources(payload):
        if not isinstance(payload, dict):
            return []
        nested = [payload[key] for key in ('task', 'event', 'meeting', 'message', 'spreadsheet', 'worksheet')
                  if isinstance(payload.get(key), dict)]
        return nested or [payload]

    @staticmethod
    def _resource_matches(service, read_arguments, resource, identity=None):
        if service == 'team_chat':
            session = resource.get('chat_session')
            actual = session.get('id') if isinstance(session, dict) else next((resource[key] for key in _FAMILIES['team_chat'][0] if key in resource), None)
            message = next((resource[key] for key in _FAMILIES['team_chat'][1] if key in resource), None)
            target = read_arguments.get('chat_session_id')
            aliases = identity.get('aliases', []) if identity and identity.get('read_target') == target else [target]
            if (identity and identity.get('expected_type') == 'direct_chat' and isinstance(session, dict)
                    and session.get('type') not in ('direct_chat', 'dm', 'direct', 'p2p')):
                return False
            # Only the typed chat_session.id or an explicit legacy root field
            # represents a recipient. A sender/quote/attachment ID never does.
            return (actual is not None and actual in aliases and message is not None
                    and str(message) == str(read_arguments.get('message_id')))
        targets = [(family, next((read_arguments[key] for key in family if key in read_arguments), None))
                   for family in _FAMILIES.get(service, [])]
        targets = [(family, target) for family, target in targets if target is not None]
        if not targets:
            return False
        for family, target in targets:
            returned = next((resource[key] for key in family if key in resource), None)
            # An echoed body without resource identity cannot prove which item
            # was read. A correct ID elsewhere (for example a quote) is not proof.
            if returned is None and service == 'sheets' and 'sheetId' in family:
                # Documented read shape echoes worksheetId/range, not sheetId;
                # the exact sheetId remains bound to the read request itself.
                continue
            if returned is None or str(returned) != str(target):
                return False
        return True

    @staticmethod
    def _response_target_matches(service, read_arguments, response, identity=None):
        return any(ZoomGenericWriter._resource_matches(service, read_arguments, resource, identity)
                   for resource in ZoomGenericWriter._resources(_payload(response)))

    def _contract(self, service, tool, arguments, kind):
        if operation_kind(service, tool, arguments) != kind:
            raise ZoomError('read_only', 'This operation does not match the audited Zoom read/write policy. Nothing was sent.')
        metadata = self.zoom._schema(service, tool)
        schema = metadata['inputSchema']
        _validate_arguments(arguments, schema)
        if any(key not in schema.get('properties', {}) for key in arguments):
            raise ZoomError('invalid_argument', 'Only exact parameters from the current Zoom schema are allowed.')
        if kind == 'write' and service == 'sheets':
            if tool == 'sheets_edit_cells':
                self._sheet_values(arguments)
            elif tool == 'sheets_create_spreadsheet':
                for sheet in arguments.get('sheets', []):
                    self._sheet_values(sheet)
        return metadata

    @staticmethod
    def _sheet_values(arguments):
        # Literal writes use start-cell or exact rectangle ranges. Keep this
        # shape check independent from the narrow upstream schema correction.
        appended = arguments.get('appendRows')
        if appended is not None:
            if set(appended) - {'values'}:
                raise ZoomError('invalid_argument', 'Only values are supported in appendRows.')
            rows = appended['values']
            if not rows or not rows[0] or any(len(row) != len(rows[0]) for row in rows):
                raise ZoomError('invalid_argument', 'Appended Sheet values must form a non-empty rectangle.')
        groups = [(group, 'values') for group in arguments.get('cellValues', [])]
        groups += [(group, 'formulas') for group in arguments.get('cellFormulas', [])]
        for group, field in groups:
            if set(group) - {'range', field}:
                raise ZoomError('invalid_argument', 'Only range and the documented cell matrix are supported in a Sheet write group.')
            rows = group[field]
            if not rows or not rows[0] or any(len(row) != len(rows[0]) for row in rows):
                raise ZoomError('invalid_argument', 'Sheet cell values and formulas must form a non-empty rectangle.')
            if field == 'formulas' and any(not isinstance(item, str) or not item.startswith('=') for row in rows for item in row):
                raise ZoomError('invalid_argument', 'Each Sheet formula must be a string starting with =.')
            match = re.fullmatch(r'([A-Za-z]+)([1-9][0-9]*)(?::([A-Za-z]+)([1-9][0-9]*))?', group['range'])
            if match is None:
                raise ZoomError('invalid_argument', 'Use a start cell or one concrete A1 rectangle for cell values and formulas.')
            def column(value):
                result = 0
                for letter in value.upper():
                    result = result * 26 + ord(letter) - ord('A') + 1
                return result
            if match[3] is not None:
                height = int(match[4]) - int(match[2]) + 1
                width = column(match[3]) - column(match[1]) + 1
                if height != len(rows) or width != len(rows[0]):
                    raise ZoomError('invalid_argument', 'The Sheet cell matrix must match its A1 range exactly.')

    def _verification_request(self, value):
        if value is None:
            return None
        if (not isinstance(value, dict) or set(value) - {'service', 'tool', 'arguments', 'expected_fields'}
                or not isinstance(value.get('arguments'), dict)):
            raise ZoomError('invalid_argument', 'Verification requires an exact read service, tool, and arguments.')
        service = self.zoom._identifier(value.get('service'))
        tool = self.zoom._identifier(value.get('tool'))
        arguments = value['arguments']
        self._contract(service, tool, arguments, 'read')
        expected = value.get('expected_fields', {})
        if (not isinstance(expected, dict) or len(expected) > 32
                or any(not isinstance(key, str) or not re.fullmatch(r'[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*', key)
                       or isinstance(item, (dict, list)) or not isinstance(item, (str, int, float, bool, type(None)))
                       for key, item in expected.items())
                or len(encoded(value).encode()) > 48000):
            raise ZoomError('invalid_argument', 'Verification expected_fields accepts at most 32 dotted JSON paths with scalar values.')
        return value

    def _automatic_verification(self, service, tool, arguments, result):
        payload = _payload(result)
        identity = lambda *keys: next((arguments[key] for key in keys if arguments.get(key) is not None), None) or _find(payload, keys)
        if service == 'team_chat' and tool in ('team_chat_msg_send', 'team_chat_msg_update', 'team_chat_msg_reply_to_trigger_thread'):
            if arguments.get('schedule_time'):
                return None
            message = identity('message_id', 'messageId', 'messageID', 'id')
            if message and arguments.get('chat_session_id') and arguments.get('message_content') is not None:
                return {'service': service, 'tool': 'team_chat_msg_get_by_id',
                        'arguments': {'message_id': str(message), 'chat_session_id': arguments['chat_session_id']},
                        '_automatic_fields': {'message_content': (arguments['message_content'], ('message_content', 'content', 'text'))}}
        if service == 'tasks' and tool in ('tasks_create', 'task_update'):
            task = identity('taskId', 'task_id', 'id')
            fields = {key: (arguments[key], (key,)) for key in ('title', 'description', 'status', 'priority', 'due_date', 'is_public', 'starred') if key in arguments}
            if task and fields:
                return {'service': service, 'tool': 'tasks_get', 'arguments': {'taskId': str(task)}, '_automatic_fields': fields}
        if service == 'calendar' and tool in ('calendar_insert_event', 'calendar_patch_event'):
            event = identity('event_id', 'eventId', 'id')
            fields = {key: (arguments[key], (key,)) for key in ('summary', 'description', 'location', 'status') if key in arguments}
            if event and arguments.get('cal_id') and fields:
                targets = {key: arguments[key] for key in ('cal_id', 'service', 'calendarId', 'instanceDateTime', 'useICalUid', 'mailbox') if key in arguments}
                targets['event_id'] = str(event)
                return {'service': service, 'tool': 'calendar_get_event', 'arguments': targets, '_automatic_fields': fields}
        if service == 'meeting' and tool in ('meeting_create', 'meeting_basic_update'):
            meeting = identity('meetingId', 'meeting_id', 'id')
            fields = {key: (arguments[key], (key,)) for key in ('topic', 'duration', 'agenda', 'password') if key in arguments}
            if meeting and fields:
                targets = {'meetingId': str(meeting)}
                if arguments.get('occurrence_id'):
                    targets['occurrence_id'] = arguments['occurrence_id']
                return {'service': service, 'tool': 'meeting_detail_get', 'arguments': targets, '_automatic_fields': fields}
        if service == 'sheets' and tool == 'sheets_edit_cells':
            groups = arguments.get('cellValues', [])
            if set(arguments) <= {'sheetId', 'worksheetId', 'cellValues'} and len(groups) == 1:
                group = groups[0]
                shape = self._sheet_range(group['range'], group['values'])
                return {'service': service, 'tool': 'sheets_read_cells',
                        'arguments': {'sheetId': arguments['sheetId'], 'worksheetId': arguments['worksheetId'],
                                      'range': shape, 'include': 'values', 'pageSize': min(5000, len(group['values']))},
                        '_sheet_values': group['values'], '_sheet_range': shape}
            return None
        return None

    @staticmethod
    def _sheet_range(value, values=None):
        match = re.fullmatch(r'([A-Za-z]+)([1-9][0-9]*)(?::([A-Za-z]+)([1-9][0-9]*))?', value or '')
        if match is None:
            return None
        first = match[1].upper() + match[2]
        if match[3] is not None:
            return first + ':' + match[3].upper() + match[4]
        column = 0
        for letter in match[1].upper():
            column = column * 26 + ord(letter) - ord('A') + 1
        column += len(values[0]) - 1 if values else 0
        label = ''
        while column:
            column, remainder = divmod(column - 1, 26)
            label = chr(ord('A') + remainder) + label
        row = int(match[2]) + (len(values) - 1 if values else 0)
        return first + ':' + label + str(row)

    def _team_chat_verification(self, arguments, verification):
        """Resolve only read aliases; retain the exact approved send arguments."""
        import copy
        verification = copy.deepcopy(verification)
        target = arguments.get('chat_session_id')
        if not isinstance(target, str) or not target:
            return None
        settings = self.zoom._settings() if hasattr(self.zoom, '_settings') else {}
        connection = settings.get('connection_id')
        aliases = {target}
        preferred = target
        account = None
        source = 'exact_session_id'
        domain = target.rsplit('@', 1)[-1].lower() if '@' in target else ''
        is_email = bool(re.fullmatch(r'[^@\s]+@[^@\s]+\.[^@\s]+', target)) and not domain.startswith(('conference.', 'xmpp'))
        if is_email:
            try:
                query = {'service': 'contact', 'tool': 'contacts_search',
                         'arguments': {'keyword': target, 'fieldsMode': 'minimal', 'from': 0, 'limit': 100}}
                self._contract('contact', 'contacts_search', query['arguments'], 'read')
                payload = _payload(self._fresh_read(query))
                users = payload.get('users') if isinstance(payload, dict) else None
                total = payload.get('totalCount') if isinstance(payload, dict) else None
                if (not isinstance(users, list) or type(total) is not int or total > len(users)):
                    return None
                matches = {}
                for user in users:
                    if (isinstance(user, dict) and isinstance(user.get('email'), str)
                            and user['email'].casefold() == target.casefold()
                            and isinstance(user.get('userId'), str) and user['userId']):
                        matches[user['userId']] = user
                if len(matches) != 1:
                    return None
                preferred, user = next(iter(matches.items()))
                account = user.get('accountId')
                aliases.add(preferred)
                source = 'fresh_exact_contact_email'
            except (ZoomError, ValueError, TypeError):
                return None
        # Only an actual metadata response for this one exact identifier can add
        # aliases. No blanket lowercase comparison applies to returned IDs.
        try:
            query = {'service': 'team_chat', 'tool': 'team_chat_session_metadata_fetch',
                     'arguments': {'chat_session_id': preferred}}
            self._contract('team_chat', query['tool'], query['arguments'], 'read')
            payload = _payload(self._fresh_read(query))
            rows = payload if isinstance(payload, list) else payload.get('data') if isinstance(payload, dict) else None
            if isinstance(rows, list) and len(rows) == 1 and isinstance(rows[0], dict):
                row = rows[0]
                same_account = not account or row.get('chat_session_counterpart_account_id') == account
                # A fresh same-object metadata response can demonstrate UID/JID
                # case aliases, without granting equivalence to another user.
                stem = preferred.split('@', 1)[0].casefold()
                candidates = [row.get('chat_session_id'), row.get('chat_session_counterpart_jid')]
                demonstrated = [item for item in candidates if isinstance(item, str)
                                and item.split('@', 1)[0].casefold() == stem]
                if same_account and demonstrated and (not is_email or row.get('chat_session_type') == 'direct_chat'):
                    aliases.update(demonstrated)
                    source += '+fresh_session_metadata'
        except (ZoomError, ValueError, TypeError):
            pass
        if hasattr(self.zoom, '_settings') and self.zoom._settings().get('connection_id') != connection:
            return None
        requested_target = verification['arguments'].get('chat_session_id')
        if requested_target not in aliases:
            return None
        # An email submitted to send is not assumed usable by get_by_id. The
        # exact contact UID is the proven DM read identifier.
        verification['arguments']['chat_session_id'] = preferred
        verification['_session_identity'] = {'source_target': target, 'read_target': preferred,
                                             'aliases': sorted(aliases), 'connection_id': connection,
                                             'expected_type': 'direct_chat' if is_email else None, 'source': source}
        return verification

    def _bound_verification(self, service, arguments, result, verification):
        if verification['service'] != service:
            return False
        read_args = verification['arguments']
        if service == 'sheets' and arguments.get('cellValues'):
            ranges = [self._sheet_range(group['range'], group['values']) for group in arguments['cellValues']]
            if (verification['tool'] != 'sheets_read_cells'
                    or self._sheet_range(read_args.get('range')) not in ranges):
                return False
        families = _FAMILIES.get(service, [])
        if not families:
            return False
        matched = False
        for family in families:
            wanted = next((arguments[key] for key in family if key in arguments), None)
            if wanted is None:
                wanted = _find(_payload(result), family)
            provided = next((read_args[key] for key in family if key in read_args), None)
            if wanted is not None:
                if provided is None or str(provided) != str(wanted):
                    identity = verification.get('_session_identity') if service == 'team_chat' and family == _FAMILIES['team_chat'][0] else None
                    if (not identity or identity.get('source_target') != wanted
                            or identity.get('read_target') != provided or provided not in identity.get('aliases', ())
                            or identity.get('connection_id') != self.zoom._settings().get('connection_id')):
                        return False
                matched = True
            elif provided is not None:
                return False
        # Scope switches must match, including provider, calendar override,
        # mailbox and recurrence instance; an ID alone is insufficient here.
        for key in ('service', 'calendarId', 'mailbox', 'instanceDateTime', 'useICalUid', 'occurrence_id'):
            if arguments.get(key) != read_args.get(key):
                return False
        return matched

    def _fresh_read(self, verification):
        request = {key: verification[key] for key in ('service', 'tool', 'arguments')}
        result = self.zoom.read(dict(request, output_offset=0))
        if not result.get('truncated'):
            return result.get('result')
        parts, size, offset = [result['content_excerpt']], len(result['content_excerpt']), result.get('next_output_offset')
        while offset is not None and size <= 128000:
            result = self.zoom.read(dict(request, output_offset=offset))
            part = result['content_excerpt']
            parts.append(part)
            size += len(part)
            following = result.get('next_output_offset')
            if following is not None and following <= offset:
                raise ZoomError('invalid_response', 'Zoom readback did not advance.')
            offset = following
        if offset is not None:
            raise ZoomError('response_too_large', 'The readback is too broad to verify this change.')
        try:
            return json.loads(''.join(parts))
        except ValueError:
            raise ZoomError('invalid_response', 'Zoom did not return a complete readback.') from None

    @staticmethod
    def _field_bound(service, path, arguments, expected, read_arguments):
        parts = path.split('.')
        envelopes = {'data', 'result', 'task', 'event', 'meeting', 'message', 'spreadsheet', 'worksheet'}
        while len(parts) > 1 and parts[0] in envelopes:
            parts.pop(0)
        first = parts[0]
        if service == 'sheets' and arguments.get('cellValues'):
            read_range = ZoomGenericWriter._sheet_range(read_arguments.get('range'))
            groups = [group for group in arguments['cellValues']
                      if ZoomGenericWriter._sheet_range(group['range'], group['values']) == read_range]
            if len(groups) != 1:
                return False
            rows = groups[0]['values']
            if parts == ['value']:
                return len(rows) == len(rows[0]) == 1 and _same(expected, rows[0][0])
            coordinates = parts[2:] if parts[:2] == ['compact', 'values'] else parts[1:] if first == 'values' else []
            if len(coordinates) != 2 or any(not item.isdecimal() for item in coordinates):
                return False
            row, column = map(int, coordinates)
            return row < len(rows) and column < len(rows[row]) and _same(expected, rows[row][column])
        aliases = {'team_chat': {'content': 'message_content', 'text': 'message_content'},
                   'mail': {'body': 'text_body', 'content': 'text_body'},
                   'tasks': {'name': 'title'}}
        source = aliases.get(service, {}).get(first, first)
        if source not in arguments:
            return False
        # A scalar body/title cannot be proved through a quote nested beneath
        # an alias of that field. Structured writes retain their own paths.
        submitted = arguments[source]
        if len(parts) == 1:
            return _same(expected, submitted)
        if not isinstance(submitted, (dict, list)):
            return False
        return _same(expected, _lookup(submitted, '.'.join(parts[1:])))

    def verify(self, service, tool, arguments, result, requested):
        outcome = {'verified': False, 'verification': 'read_back_unavailable'}
        verification = requested or self._automatic_verification(service, tool, arguments, result)
        if verification is None:
            return outcome
        if service == 'team_chat':
            verification = self._team_chat_verification(arguments, verification)
            if verification is None:
                return dict(outcome, verification='read_back_target_unproven')
        identity = verification.get('_session_identity')
        if not self._bound_verification(service, arguments, result, verification):
            return dict(outcome, verification='read_back_target_unproven')
        expected = verification.get('expected_fields', {})
        automatic = verification.get('_automatic_fields', {})
        sheet_values = verification.get('_sheet_values')
        identity_keys = {key for family in _FAMILIES.get(service, []) for key in family}
        identity_keys.update(('service', 'calendarId', 'mailbox', 'instanceDateTime', 'useICalUid', 'occurrence_id', 'message_format'))
        submitted = list(_scalars({key: value for key, value in arguments.items() if key not in identity_keys}))
        if not automatic and sheet_values is None and (not expected
                or any(not self._field_bound(service, path, arguments, value, verification['arguments']) for path, value in expected.items())
                or any(not any(_same(item, source) for source in submitted) for item in expected.values())):
            return dict(outcome, verification='expected_fields_not_bound_to_change')
        try:
            # Automatic contracts are discovered only after the commit. A failed
            # schema or read never changes that already acknowledged commit.
            self._contract(verification['service'], verification['tool'], verification['arguments'], 'read')
            readback = self._fresh_read(verification)
            if (identity is not None and hasattr(self.zoom, '_settings')
                    and self.zoom._settings().get('connection_id') != identity.get('connection_id')):
                return dict(outcome, verification='connection_changed_during_target_resolution')
            if not self._response_target_matches(service, verification['arguments'], readback, identity):
                return dict(outcome, verification='read_back_target_mismatch', read_back={'available': True})
            if service == 'sheets' and arguments.get('cellValues'):
                expected_range = self._sheet_range(verification['arguments'].get('range'))
                if not any(self._resource_matches(service, verification['arguments'], obj, identity)
                           and not obj.get('truncated') and not obj.get('nextPageToken')
                           and self._sheet_range(obj.get('range')) == expected_range
                           for obj in self._resources(_payload(readback))):
                    return dict(outcome, verification='read_back_range_mismatch_or_incomplete')
            complete_fields = True
            if sheet_values is not None:
                resources = self._resources(_payload(readback))
                matched = any(self._resource_matches(service, verification['arguments'], obj, identity)
                              and not obj.get('truncated') and not obj.get('nextPageToken')
                              and self._sheet_range(obj.get('range')) == verification['_sheet_range']
                              and _same(_lookup(obj, 'compact.values'), sheet_values)
                              for obj in resources)
                fields = ['compact.values', 'range', 'worksheetId']
            elif automatic:
                objects = self._resources(_payload(readback))
                complete_fields = any(self._resource_matches(service, verification['arguments'], obj, identity)
                                      and all(any(alias in obj for alias in aliases) for _, aliases in automatic.values())
                                      for obj in objects)
                matched = next((obj for obj in objects if self._resource_matches(service, verification['arguments'], obj, identity)
                                and all(any(_same(obj.get(alias, _MISSING), value) for alias in aliases)
                                        for value, aliases in automatic.values())), None) is not None
                fields = sorted(automatic)
            else:
                matched = all(any(_same(_lookup(layer, path), value) for layer in _layers(readback))
                              for path, value in expected.items())
                fields = sorted(expected)
            outcome.update(verified=matched, verification='verified' if matched else 'read_back_mismatch',
                           verification_scope='requested_fields_only',
                           read_back={'service': verification['service'], 'tool': verification['tool'],
                                      'available': True, 'complete_requested_fields': complete_fields,
                                      'matched_fields': fields if matched else []})
        except (ZoomError, ValueError, TypeError):
            pass
        if identity is not None and outcome.get('read_back'):
            outcome['read_back']['target_resolution'] = identity['source']
        return outcome

    def write(self, args):
        self.zoom._require_enabled()
        service, tool = self.zoom._identifier(args.get('service')), self.zoom._identifier(args.get('tool'))
        if service == 'docs' and tool in DOCUMENT_WRITE_TOOLS:
            raise ZoomError('invalid_argument', 'This Docs change must use the document-specific writer.')
        if self.zoom.gate is None:
            raise ZoomError('approval_unavailable', 'Zoom changes require the current Pico task authorization context.')
        arguments = args.get('arguments')
        if not isinstance(arguments, dict) or len(encoded(arguments).encode()) > 160000:
            raise ZoomError('invalid_argument', 'Use a bounded argument object matching the exact Zoom schema. No content was truncated or sent.')
        arguments = json.loads(encoded(arguments))
        operation, reason = args.get('operation_id'), args.get('reason')
        if not isinstance(operation, str) or not re.fullmatch(r'[A-Za-z0-9_.:-]{8,128}', operation):
            raise ZoomError('invalid_argument', 'Use a unique operation_id and reuse it only for an identical retry.')
        if not isinstance(reason, str) or not reason.strip() or len(reason) > 4000:
            raise ZoomError('invalid_argument', 'Describe this requested Zoom change concisely.')
        connection = self.zoom._settings().get('connection_id')
        if not isinstance(connection, str) or not connection:
            raise ZoomError('disconnected', 'Reconnect Zoom in Pico before making changes.')
        verification = json.loads(encoded(args.get('verification'))) if args.get('verification') is not None else None
        fingerprint = hashlib.sha256(encoded({'service': service, 'tool': tool, 'arguments': arguments}).encode()).hexdigest()
        journal = OperationJournal(self.zoom.data)
        try:
            previous = ZoomGenericWriter._previous(journal, operation, fingerprint, connection)
            if previous is not None:
                return previous
            # An uncertain send must not be disguised as a fresh operation ID.
            prior = journal.db.execute("SELECT id FROM operations WHERE fingerprint=? AND connection=? AND state IN ('in_flight','outcome_unknown') LIMIT 1", (fingerprint, connection)).fetchone()
            if prior:
                raise ZoomError('outcome_unknown', 'An identical change may already have reached Zoom. Inspect its actual state; do not resend it with a new operation_id.')
            self._contract(service, tool, arguments, 'write')
            verification = self._verification_request(verification)
            if service == 'mail' and tool == 'mcp_send_message' and not any(isinstance(arguments.get(key), str) and arguments[key].strip() for key in ('text_body', 'html_body')):
                raise ZoomError('invalid_argument', 'A message needs a non-empty body. Nothing was sent.')
            generation = getattr(self.zoom.gate, 'generation', None)
            preflight = None
            if (service == 'tasks' and tool == 'task_update'
                    and set(arguments) <= _TASK_UPDATE_FIELDS | {'taskId'}):
                preflight = self.verify(service, tool, arguments, {}, None)
                self._check(generation, connection)
            action = {'app': 'Zoom', 'kind': 'zoom_write', 'service': service, 'tool': tool,
                      'arguments': arguments, 'operation_id': operation, 'reason': reason,
                      'effects': operation_effects(service, tool, arguments)}
            if verification is not None:
                action['verification'] = verification
            reviewed = encoded(action)
            exact = self.zoom.gate.ask(action, {'connection_id': connection, 'request_generation': generation})
            if exact is None:
                if self._claim(journal, operation, fingerprint, connection) is None:
                    journal.finish(operation, 'failed', {'state': 'denied', 'message': 'This change was not approved. No request was sent.'})
                raise ZoomError('denied', 'This change was not approved. No request was sent.')
            if encoded(exact) != reviewed:
                raise ZoomError('invalid_approval', 'The approved Zoom change differs from the reviewed action. Nothing was sent.')
            self._check(generation, connection)
            previous = self._claim(journal, operation, fingerprint, connection)
            if previous is not None:
                return previous
            try:
                self._check(generation, connection)
            except BaseException:
                journal.finish(operation, 'failed', {'state': 'superseded', 'message': 'This change was superseded before submission. Nothing was sent.'})
                raise
            recovered = None
            try:
                raw = self.zoom._command([service, tool, '--args-json', encoded(exact['arguments'])])
                response = _sanitize(_json_output(raw))
                if _has_failure(response):
                    raise _failure(encoded(response))
            except BaseException as error:
                self.zoom._read_cache.clear()
                if isinstance(error, ZoomError) and error.state in ('needs_login', 'permission_denied', 'missing_helper'):
                    journal.finish(operation, 'failed', {'state': error.state, 'message': str(error)})
                    self.zoom._remember_error(error)
                    raise
                if (isinstance(error, ZoomError) and error.state == 'empty_response'
                        and service == 'tasks' and tool == 'task_update' and preflight
                        and preflight.get('verification') == 'read_back_mismatch'
                        and preflight.get('read_back', {}).get('available')
                        and preflight.get('read_back', {}).get('complete_requested_fields') is True):
                    try:
                        self._check(generation, connection)
                        confirmation = self.verify(service, tool, arguments, {}, None)
                        self._check(generation, connection)
                        if confirmation.get('verified'):
                            recovered = confirmation
                            response = {}
                    except (ZoomError, ValueError):
                        pass
                if recovered is None:
                    journal.finish(operation, 'outcome_unknown', {})
                    if not isinstance(error, Exception):
                        raise
                    raise ZoomError('outcome_unknown', 'Zoom did not confirm this change. It may already have been applied. Inspect its state before retrying; do not submit it again automatically.') from None
            self.zoom._read_cache.clear()
            if recovered is None and not _acknowledged(response, tool):
                journal.finish(operation, 'outcome_unknown', {})
                raise ZoomError('outcome_unknown', 'Zoom returned no reliable acknowledgement. The change may already exist. Read its actual state before retrying.')
            outcome = {'committed': True, 'verified': False, 'verification': 'read_back_unavailable',
                       'service': service, 'tool': tool, 'operation_id': operation,
                       'replayed': False, 'untrusted': True, 'result': _summary(response),
                       'notice': 'Zoom acknowledged this change. Incomplete readback is not a reason to repeat it.'}
            if self.zoom._settings().get('enabled') is True and self.zoom._settings().get('connection_id') == connection:
                self.zoom._verified(service, read=False)
                outcome.update(recovered or self.verify(service, tool, arguments, response, verification))
                if recovered is not None:
                    outcome.update(provider_acknowledged=False, commit_evidence='changed_fields_fresh_readback',
                                   verification='verified_after_empty_response', verification_scope='all_submitted_task_fields')
            else:
                outcome['verification'] = 'connection_changed_after_commit'
            if outcome['verified']:
                outcome.pop('notice', None)
            journal.finish(operation, 'completed', outcome)
            return outcome
        finally:
            journal.close()
