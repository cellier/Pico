"""Single-submit boundary for Zoom changes made through an already signed-in UI.

This does not connect a browser, authenticate, infer API support, or attest that a
cloud object was saved. MacBridge still validates the actual application, fresh
observation, approval, desktop lock and cancellation before dispatching one short
native action. A durable intent record prevents an uncertain UI commit from
being repeated with another button, observation, process or operation ID.
"""
import copy
import hashlib
import math
from pathlib import Path
import re
import time
from urllib.parse import urlsplit

from mac_bridge import SAFE_KEYS
from zoom_connector import ZoomError, _validate_arguments
from zoom_documents import OperationJournal, encoded


OPERATIONS = ('create', 'update', 'delete', 'share', 'send', 'upload', 'import', 'export', 'manage')
_NOTICE = ('Only the final UI action was issued; this is not confirmation that Zoom saved or applied the change. '
           'Use mac_observe, and reopen the actual item when possible, to verify the correct product, account, '
           'target, exact content and saved state. Do not repeat this commit or use a new operation_id to verify it.')


def _schema(string):
    action = {
        'type': 'object', 'additionalProperties': False,
        'description': 'One final atomic native UI action against a fresh mac_observe. Autosaved text edits also commit changes. No scripts, batches, or extra fields.',
        'properties': {
            'app': string('Exact application PID, name or bundle ID from mac_apps.'),
            'observation_id': string('Fresh mac_observe observation_id for this exact app and final control.'),
            'kind': {'type': 'string', 'enum': ['click', 'ax_press', 'key', 'type', 'ax_set']},
            'x': {'type': 'number', 'minimum': 0}, 'y': {'type': 'number', 'minimum': 0},
            'element_index': {'type': 'integer', 'minimum': 0},
            'key': string('One exact final keyboard shortcut, for example cmd+return. No newline or batch.'),
            'text': {'type': 'string', 'maxLength': 160000,
                     'description': 'Exact original text for this autosaved insertion or field replacement. The same complete text must occur as a scalar string in expected.'},
        },
        'required': ['app', 'observation_id', 'kind'],
        'oneOf': [
            {'properties': {'kind': {'enum': ['click']}}, 'required': ['x', 'y']},
            {'properties': {'kind': {'enum': ['ax_press']}}, 'required': ['element_index']},
            {'properties': {'kind': {'enum': ['key']}}, 'required': ['key']},
            {'properties': {'kind': {'enum': ['type']}}, 'required': ['text']},
            {'properties': {'kind': {'enum': ['ax_set']}}, 'required': ['element_index', 'text']},
        ],
    }
    properties = {
        'product': string('Exact Zoom product, such as slides, paper, docs, sheets, team_chat or calendar.'),
        'operation': {'type': 'string', 'enum': list(OPERATIONS)},
        'target': {
            'type': 'object', 'additionalProperties': False,
            'properties': {
                'account': string('Exact signed-in account identity already verified in the relevant UI; never infer it from an API login.'),
                'resource': string('Stable exact item/recipient ID or canonical URL. For creation use the verified destination workspace/folder identity. Never use a button label or screen coordinates.'),
                'url': string('Optional observed current UI URL for the approval context. Do not invent one.'),
            },
            'required': ['account', 'resource'],
        },
        'expected': {
            'type': 'object',
            'description': 'Complete stable user-requested outcome: exact title, original body, changed values, recipients, access or destination as relevant. Include only requested content/changes, never observation IDs, coordinates, run IDs, nonces or changing retry markers. This is a verification criterion, not proof.',
        },
        'action': action,
        'operation_id': string('Unique operation ID for this intended commit. Reuse exactly to inspect its existing result; never change it to repeat an uncertain commit.'),
        'reason': string('Concise user-language description of this exact requested change and its consequences.'),
    }
    return {'type': 'object', 'properties': properties, 'required': list(properties), 'additionalProperties': False}


def _bounded_json(value, *, depth=0):
    if depth > 20:
        raise ZoomError('invalid_argument', 'Keep the exact Zoom UI outcome within 20 JSON levels.')
    if isinstance(value, dict):
        if any(not isinstance(key, str) or len(key) > 256 for key in value):
            raise ZoomError('invalid_argument', 'Zoom UI outcome keys must be short strings.')
        for child in value.values():
            _bounded_json(child, depth=depth + 1)
    elif isinstance(value, list):
        for child in value:
            _bounded_json(child, depth=depth + 1)
    elif type(value) is float:
        if not math.isfinite(value):
            raise ZoomError('invalid_argument', 'Zoom UI outcome numbers must be finite.')
    elif not isinstance(value, (str, int, bool, type(None))):
        raise ZoomError('invalid_argument', 'Use only JSON values for the exact Zoom UI outcome.')


class ZoomUICommit:
    def __init__(self, data, mac):
        self.data = Path(data)
        self.mac = mac
        self.schema = _schema(lambda description: {'type': 'string', 'description': description})

    def _validate(self, raw):
        _validate_arguments(raw, self.schema)
        _bounded_json(raw)
        if len(encoded(raw).encode()) > 2100000:
            raise ZoomError('invalid_argument', 'The exact Zoom UI change is too large; no content was truncated or submitted.')
        args = copy.deepcopy(raw)
        if not re.fullmatch(r'[a-z][a-z0-9_]{0,63}', args['product']):
            raise ZoomError('invalid_argument', 'Use an exact lowercase Zoom product ID.')
        if not re.fullmatch(r'[A-Za-z0-9_.:-]{8,128}', args['operation_id']):
            raise ZoomError('invalid_argument', 'Use a stable unique operation_id for this one intended Zoom UI commit.')
        if not args['reason'].strip() or len(args['reason']) > 4000:
            raise ZoomError('invalid_argument', 'Describe this exact requested Zoom UI change concisely.')
        target = args['target']
        for key, limit in (('account', 512), ('resource', 4096)):
            if not target[key].strip() or len(target[key]) > limit or any(character in target[key] for character in '\r\n\x00'):
                raise ZoomError('invalid_argument', 'Supply the exact observed Zoom account and stable target identity.')
        if 'url' in target:
            try:
                url = urlsplit(target['url'])
                valid = url.scheme in ('http', 'https') and bool(url.hostname) and not url.username and not url.password
            except ValueError:
                valid = False
            if not valid or len(target['url']) > 8192 or any(character in target['url'] for character in '\r\n\x00'):
                raise ZoomError('invalid_argument', 'Use an observed HTTP(S) UI URL without credentials.')
        if not args['expected'] or len(encoded(args['expected']).encode()) > 1000000:
            raise ZoomError('invalid_argument', 'Supply the complete bounded expected Zoom outcome; an empty description is not enough.')
        action = args['action']
        common = {'app', 'observation_id', 'kind'}
        required = {'click': {'x', 'y'}, 'ax_press': {'element_index'}, 'key': {'key'},
                    'type': {'text'}, 'ax_set': {'element_index', 'text'}}[action['kind']]
        if set(action) != common | required:
            raise ZoomError('invalid_argument', 'Only the exact fields for one atomic click, ax_press, key, type or ax_set action are allowed.')
        if not action['app'].strip() or not action['observation_id'].strip():
            raise ZoomError('invalid_argument', 'Observe the exact target app before the final Zoom UI action.')
        if action['kind'] == 'click' and any(type(action[key]) not in (int, float) or not math.isfinite(action[key]) for key in ('x', 'y')):
            raise ZoomError('invalid_argument', 'Use finite coordinates from the current app screenshot.')
        if action['kind'] in ('ax_press', 'ax_set') and type(action['element_index']) is not int:
            raise ZoomError('invalid_argument', 'Use an actual AX element index from the latest observation.')
        if action['kind'] == 'key' and not re.fullmatch(r'[A-Za-z0-9+_ -]{1,64}', action['key']):
            raise ZoomError('invalid_argument', 'Use one exact final keyboard shortcut, without a newline or batch.')
        if action['kind'] == 'key' and action['key'].lower() in SAFE_KEYS:
            raise ZoomError('invalid_argument', 'Use normal mac_action for navigation. zoom_ui_commit requires an actual final action with exact native authorization.')
        if action['kind'] in ('type', 'ax_set'):
            def strings(value):
                if isinstance(value, str):
                    yield value
                elif isinstance(value, dict):
                    for item in value.values():
                        yield from strings(item)
                elif isinstance(value, list):
                    for item in value:
                        yield from strings(item)
            if len(action['text']) > 160000 or action['text'] not in strings(args['expected']):
                raise ZoomError('invalid_argument', 'The exact autosaved text must occur as a complete scalar string in expected. No changed or unmatched text was submitted.')
        return args

    @staticmethod
    def _previous(journal, operation, fingerprint, connection):
        try:
            return journal.existing(operation, fingerprint, connection)
        except ZoomError as error:
            if error.state == 'outcome_unknown':
                raise ZoomError('outcome_unknown', 'The previous Zoom UI commit may already have happened. Observe or reopen the actual item; do not repeat it or change operation_id.') from None
            raise

    @staticmethod
    def _duplicate(journal, operation, fingerprint, connection):
        return journal.db.execute(
            "SELECT id FROM operations WHERE fingerprint=? AND connection=? AND id<>? AND state IN ('in_flight','outcome_unknown','ui_submitted') LIMIT 1",
            (fingerprint, connection, operation)).fetchone()

    @classmethod
    def _claim(cls, journal, operation, fingerprint, connection):
        # Both operation-ID and UI-intent checks happen in one transaction.
        # ui_submitted is deliberately unresolved: a successful native click
        # cannot confirm a cloud save, so a new ID cannot repeat that intent.
        journal.db.execute('BEGIN IMMEDIATE')
        try:
            previous = cls._previous(journal, operation, fingerprint, connection)
            if previous is None:
                if cls._duplicate(journal, operation, fingerprint, connection):
                    raise ZoomError('outcome_unknown', 'An identical Zoom UI commit was already issued or is uncertain. Verify its actual saved state instead of clicking again with a new operation_id.')
                journal.db.execute('INSERT INTO operations VALUES (?,?,?,?,?,?)',
                                   (operation, fingerprint, connection, 'in_flight', None, time.time()))
            journal.db.commit()
            return previous
        except BaseException:
            journal.db.rollback()
            raise

    def commit(self, raw):
        args = self._validate(raw)
        operation = args['operation_id']
        # UI account access is independent of the DevHelper connection. Never
        # assert that an API connection proves which account is open in a tab.
        account = args['target']['account'].strip().casefold()
        connection = 'zoom-ui:' + hashlib.sha256(account.encode()).hexdigest()
        # Current URL and physical control can change after submission. Only
        # the stable user target and requested change identify the intent.
        intent = {'surface': 'zoom_ui', 'product': args['product'], 'operation': args['operation'],
                  'target': {'account': account, 'resource': args['target']['resource']},
                  'expected': args['expected']}
        fingerprint = hashlib.sha256(encoded(intent).encode()).hexdigest()
        details = {key: args[key] for key in ('product', 'operation', 'target', 'expected', 'operation_id')}
        native = dict(args['action'], reason=args['reason'], zoom_ui=copy.deepcopy(details))
        generation = self.mac.gate.generation
        journal = OperationJournal(self.data)
        issued = False
        saved = None
        dispatch_error = None
        try:
            previous = self._previous(journal, operation, fingerprint, connection)
            if previous is not None:
                return previous
            if self._duplicate(journal, operation, fingerprint, connection):
                raise ZoomError('outcome_unknown', 'An identical Zoom UI commit was already issued or is uncertain. Verify its actual state; do not switch operation_id to repeat it.')
            resolved = self.mac.resolve(native['app'])
            reviewed = encoded(dict(native, app=resolved['name'], pid=resolved['pid']))

            def dispatch(exact):
                nonlocal issued, saved, dispatch_error
                try:
                    if encoded(exact) != reviewed:
                        raise ZoomError('invalid_approval', 'The final Zoom UI action differs from its exact reviewed change. Nothing was submitted.')
                    self.mac.gate.check_execution(generation)
                    saved = self._claim(journal, operation, fingerprint, connection)
                    if saved is not None:
                        return saved
                    try:
                        self.mac.gate.check_execution(generation)
                    except BaseException:
                        journal.finish(operation, 'failed', {'state': 'superseded', 'message': 'The Zoom UI change was superseded before its final action. Nothing was submitted.'})
                        raise
                    issued = True
                    self.mac.execute(exact)
                    saved = {'submitted': True, 'verified': False, 'state': 'ui_submitted',
                             'product': args['product'], 'operation': args['operation'],
                             'operation_id': operation, 'replayed': False, 'notice': _NOTICE}
                    journal.finish(operation, 'ui_submitted', saved)
                    return saved
                except BaseException as error:
                    dispatch_error = error
                    if issued:
                        journal.finish(operation, 'outcome_unknown', {})
                    raise

            try:
                result = self.mac.action(native, dispatch=dispatch)
            except BaseException as error:
                if issued and isinstance(error, Exception):
                    raise ZoomError('outcome_unknown', 'The final Zoom UI action was issued, but its outcome is uncertain. Observe or reopen the actual item; do not click again or switch operation_id.') from None
                if dispatch_error is not None:
                    raise dispatch_error
                raise
            if saved is not None:
                return saved
            return {'submitted': False, 'verified': False, 'state': result.get('status', 'not_submitted'),
                    'product': args['product'], 'operation': args['operation'], 'operation_id': operation,
                    'replayed': False, 'message': result.get('message', 'No final Zoom UI action was issued.')}
        finally:
            journal.close()


def register_zoom_ui(register, string, data, mac):
    ui = ZoomUICommit(data, mac)
    schema = _schema(string)
    register('zoom_ui_commit',
             'Issue exactly one final Zoom web/client UI commit after resolving the product, signed-in account, stable target and exact requested content in fresh UI observations. Use when the relevant account UI supports an action absent from the API. Preparation uses normal Mac tools. This does not authenticate, bypass permissions or connect a browser. The current native authorization setting applies, with all exact details shown together. Reusing an operation ID returns its issued result; a new ID cannot repeat an uncertain identical intent. submitted=true only means the UI action was issued, never that a cloud save succeeded. Observe/reopen and verify the actual product, object, content and saved state; never repeat the final action for verification.',
             schema['properties'], schema['required'], ui.commit)
    return ui
