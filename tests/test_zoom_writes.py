"""Multi-product Zoom writes against an isolated in-memory gateway only.

No DevHelper process, account, model, email or chat recipient is contacted.
"""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from zoom_connector import ZoomConnector, ZoomError, READ_TOOLS, WRITE_TOOLS


def schema(properties, required):
    return {'type': 'object', 'properties': properties, 'required': required, 'additionalProperties': False}


STRING = {'type': 'string'}
CASES = {
    'tasks': ('tasks_create', {'title': 'Private fixture task', 'skip_notifications': True},
              'tasks_get', {'taskId': 'synthetic-tasks'}, {'data.title': 'Private fixture task'}),
    'meeting': ('meeting_create', {'topic': 'Private fixture meeting', 'duration': 25, 'start_time_local': '2026-10-25T10:00:00'},
                'meeting_detail_get', {'meetingId': 'synthetic-meeting'}, {'data.topic': 'Private fixture meeting'}),
    'calendar': ('calendar_insert_event', {'cal_id': 'private-calendar', 'summary': 'Private fixture event',
                                          'start': {'dateTime': '2026-10-25T10:00:00+08:00'},
                                          'end': {'dateTime': '2026-10-25T10:25:00+08:00'}},
                 'calendar_get_event', {'cal_id': 'private-calendar', 'event_id': 'synthetic-calendar'}, {'data.summary': 'Private fixture event'}),
    'team_chat': ('team_chat_msg_send', {'chat_session_id': 'private-session', 'message_content': 'Private fixture conversation.'},
                  'team_chat_msg_get_by_id', {'message_id': 'synthetic-team_chat', 'chat_session_id': 'private-session'}, {'data.message_content': 'Private fixture conversation.'}),
    'sheets': ('sheets_edit_cells', {'sheetId': 'private-sheet', 'worksheetId': 'private-worksheet',
                                   'cellValues': [{'range': 'A1', 'values': [['Private fixture cell']]}]},
               'sheets_read_cells', {'sheetId': 'private-sheet', 'worksheetId': 'private-worksheet', 'range': 'A1'}, {'data.value': 'Private fixture cell'}),
    'mail': ('mcp_send_message', {'to': ['nobody@example.invalid'], 'subject': 'Private fixture email', 'text_body': 'No real message is sent.'},
             'zmail_get_email', {'message_id': 'synthetic-mail'}, {'data.text_body': 'No real message is sent.'}),
}

WRITE_SCHEMAS = {
    'tasks_create': schema({'title': dict(STRING, minLength=1), 'skip_notifications': {'type': 'boolean'}}, ['title']),
    'meeting_create': schema({'topic': STRING, 'duration': {'type': 'integer', 'minimum': 1}, 'start_time_local': STRING}, ['topic', 'duration', 'start_time_local']),
    'calendar_insert_event': schema({'cal_id': STRING, 'summary': STRING,
                                     'start': schema({'dateTime': STRING}, ['dateTime']),
                                     'end': schema({'dateTime': STRING}, ['dateTime'])}, ['cal_id', 'start', 'end']),
    'team_chat_msg_send': schema({'chat_session_id': STRING, 'message_content': dict(STRING, minLength=1, maxLength=3200)}, ['chat_session_id', 'message_content']),
    'sheets_edit_cells': schema({'sheetId': STRING, 'worksheetId': STRING, 'cellValues': {'type': 'array', 'minItems': 1,
        'items': schema({'range': STRING, 'values': {'type': 'array', 'items': {'type': 'array', 'items': STRING}}}, ['range', 'values'])}}, ['sheetId', 'worksheetId']),
    'mcp_send_message': schema({'to': {'type': 'array', 'minItems': 1, 'items': STRING}, 'subject': STRING, 'text_body': STRING}, ['to', 'subject']),
}
READ_SCHEMAS = {
    read_tool: schema({name: STRING for name in arguments}, list(arguments))
    for _, _, read_tool, arguments, _ in CASES.values()
}


def conflicting_sheet_schema():
    """Faithful fragments of the gateway's protobuf Value contradiction."""
    cell = {'type': 'object', 'properties': {},
            'description': 'A single cell value: string, number, boolean, or null to clear the cell.'}
    matrix = {'type': 'array', 'items': {'type': 'array', 'items': cell}}
    formulas = copy.deepcopy(matrix)
    formulas['description'] = '2D array of formulas. Each element is a string starting with "=", e.g. "=SUM(A2:D2)".'
    return schema({'sheetId': STRING, 'worksheetId': STRING,
                   'cellValues': {'type': 'array', 'items': {'type': 'object',
                       'properties': {'range': STRING, 'values': copy.deepcopy(matrix)},
                       'required': ['range', 'values']}},
                   'appendRows': {'type': 'object', 'properties': {'values': copy.deepcopy(matrix)}, 'required': ['values']},
                   'cellFormulas': {'type': 'array', 'items': {'type': 'object',
                       'properties': {'range': STRING, 'formulas': formulas}, 'required': ['range', 'formulas']}},
                   'cellFormats': {'type': 'array', 'items': {'type': 'object',
                       'properties': {'format': copy.deepcopy(cell)}, 'required': ['format']}}},
                  ['sheetId', 'worksheetId'])


def conflicting_create_sheet_schema():
    tab = copy.deepcopy(conflicting_sheet_schema()['properties'])
    for key in ('sheetId', 'worksheetId', 'appendRows'):
        tab.pop(key)
    tab['name'] = STRING
    return schema({'fileName': STRING, 'parentId': STRING,
                   'sheets': {'type': 'array', 'items': {'type': 'object', 'properties': tab}}}, [])


class Gate:
    def __init__(self):
        self.calls = []
        self.deny = False
        self.on_ask = None
        self.generation = 0
        self.execution_check = None

    def invalidate_pending(self):
        self.generation += 1

    def check_execution(self, generation=None):
        if self.execution_check:
            self.execution_check()
        if generation is not None and generation != self.generation:
            raise ValueError('The conversation changed; the approved action is stale.')

    def ask(self, action, context):
        self.check_execution()
        self.calls.append((copy.deepcopy(action), copy.deepcopy(context)))
        if self.on_ask:
            self.on_ask(action, context)
        return None if self.deny else copy.deepcopy(action)


class Helper:
    """Metadata and payload fixtures, with zero execution outside this object."""
    def __init__(self):
        self.calls = []
        self.writes = []
        self.fail = None
        self.ack = None
        self.read_failure = None
        self.read_overrides = {}
        self.before_read = None
        self.missing_tools = set()
        self.schema_overrides = {}
        self.read_sequences = {}
        self.after_write = None

    def __call__(self, argv):
        args = argv[2:-1]
        self.calls.append(copy.deepcopy(args))
        service = args[0]
        if len(args) == 1:
            tools = READ_TOOLS.get(service, frozenset()) | WRITE_TOOLS.get(service, frozenset())
            return json.dumps([{'name': tool} for tool in sorted(tools) if tool not in self.missing_tools])
        if args[1] == 'schema':
            return 'Input Schema:\n' + json.dumps(self.schema_overrides.get(args[2], WRITE_SCHEMAS.get(args[2], READ_SCHEMAS.get(args[2], schema({}, [])))))
        tool, values = args[1], json.loads(args[-1])
        if tool in WRITE_TOOLS.get(service, ()):
            self.writes.append((service, tool, copy.deepcopy(values)))
            if self.after_write:
                self.after_write(service, tool, values)
            if self.fail:
                raise self.fail
            if self.ack is not None:
                return json.dumps(copy.deepcopy(self.ack))
            identity = 'synthetic-' + service
            return json.dumps({'data': {'success': True, 'id': identity, 'task_id': identity,
                                       'message_id': identity, 'event_id': identity, 'meeting_id': identity,
                                       'access_token': 'do-not-persist-this-secret'}})
        if self.before_read:
            self.before_read()
        if self.read_failure:
            raise self.read_failure
        if tool in self.read_sequences:
            value = self.read_sequences[tool].pop(0)
            if isinstance(value, Exception):
                raise value
            return json.dumps(copy.deepcopy(value))
        if tool in self.read_overrides:
            return json.dumps(copy.deepcopy(self.read_overrides[tool]))
        _, sent, _, _, _ = CASES[service]
        identity = 'synthetic-' + service
        content = dict(sent, id=identity, task_id=identity, message_id=identity,
                       event_id=identity, meeting_id=identity, value='Private fixture cell')
        if service == 'sheets':
            content.update(range=values.get('range'), truncated=False, nextPageToken='')
        return json.dumps({'data': content})


class ZoomWriteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.data = Path(self.temp.name)
        self.settings = self.data / 'zoom-connection.json'
        self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'private-connection'}))
        self.helper = Helper()
        self.gate = Gate()
        self.zoom = self.reopen()

    def tearDown(self):
        self.temp.cleanup()

    def reopen(self):
        return ZoomConnector(self.data, helper='/usr/bin/true', runner=self.helper, gate=self.gate)

    def args(self, service='tasks', *, verify=False, **extra):
        tool, arguments, read_tool, read_args, expected = CASES[service]
        value = {'service': service, 'tool': tool, 'arguments': copy.deepcopy(arguments),
                 'operation_id': str(uuid.uuid4()), 'reason': 'Perform only this isolated fixture change.'}
        if verify:
            value['verification'] = {'service': service, 'tool': read_tool, 'arguments': copy.deepcopy(read_args),
                                     'expected_fields': copy.deepcopy(expected)}
        value.update(extra)
        return value

    def sheet_contract(self):
        self.helper.schema_overrides['sheets_edit_cells'] = conflicting_sheet_schema()
        self.helper.schema_overrides['sheets_create_spreadsheet'] = conflicting_create_sheet_schema()
        self.helper.schema_overrides['sheets_read_cells'] = schema(
            {'sheetId': STRING, 'worksheetId': STRING, 'range': STRING,
             'include': STRING, 'pageSize': {'type': 'integer'}}, ['sheetId', 'worksheetId'])

    def task_update_contract(self):
        self.helper.schema_overrides['task_update'] = schema(
            {'taskId': STRING, 'title': STRING, 'description': STRING, 'due_date': STRING,
             'priority': dict(STRING, enum=['Low', 'Medium', 'High', 'Highest']),
             'status': dict(STRING, enum=['To do', 'In progress', 'Done', 'Blocked', 'Recommended']),
             'is_public': {'type': 'boolean'}, 'starred': {'type': 'boolean'}}, ['taskId'])

    def task_update(self):
        return self.args('tasks', tool='task_update', arguments={'taskId': 'synthetic-tasks',
            'title': 'Updated title', 'description': 'Updated description', 'status': 'In progress',
            'priority': 'High', 'due_date': '2026-10-28', 'is_public': False, 'starred': True})

    def team_chat_contacts_contract(self, rows):
        self.helper.schema_overrides['contacts_search'] = schema(
            {'keyword': STRING, 'fieldsMode': dict(STRING, enum=['minimal', 'standard', 'full']),
             'from': {'type': 'integer', 'minimum': 0}, 'limit': {'type': 'integer', 'minimum': 0, 'maximum': 100}}, ['keyword'])
        self.helper.read_overrides['contacts_search'] = {'users': rows, 'totalCount': len(rows)}

    @staticmethod
    def native_chat_message(session, *, content='Private fixture conversation.', message='synthetic-team_chat'):
        # The actual native self-chat read shape, with only synthetic identities.
        return {'_tracking_id': 'private-fixture-tracking', 'data': {
            'chat_session': {'id': session, 'name': 'Private fixture', 'type': 'dm'},
            'content': content, 'message_id': message, 'type': 'text',
            'sender': {'name': 'Synthetic sender', 'user_id': 'private-sender'},
            'metadata': {'deep_link': 'https://example.invalid/synthetic-message'}}, 'result': 0}

    def test_six_services_use_discovered_schema_exact_gate_and_confirmed_ack(self):
        self.helper.read_failure = ZoomError('permission_denied', 'Readback is deliberately unavailable in this fixture')
        for service in CASES:
            with self.subTest(service=service):
                args = self.args(service)
                result = self.zoom.write(args)
                self.assertTrue(result['committed'])
                self.assertFalse(result['verified'], 'A provider acknowledgement alone is not content readback')
                self.assertEqual(self.helper.writes[-1], (service, args['tool'], args['arguments']))
                action, context = self.gate.calls[-1]
                self.assertEqual(action['arguments'], args['arguments'])
                self.assertEqual(context['connection_id'], 'private-connection')
                self.assertNotIn('do-not-persist-this-secret', json.dumps(result))
        self.assertEqual(len(self.helper.writes), len(CASES))
        self.assertEqual(len(self.gate.calls), len(CASES))

    def test_multi_service_exact_readback_verifies_the_intended_resource_and_fields(self):
        for service in CASES:
            with self.subTest(service=service):
                result = self.zoom.write(self.args(service, verify=True))
                self.assertTrue(result['committed'] and result['verified'])
        self.assertEqual(len(self.helper.writes), len(CASES))

    def test_same_operation_is_durable_and_conflicts_across_arguments_service_and_account(self):
        args = self.args()
        first = self.zoom.write(args)
        replay = self.reopen().write(copy.deepcopy(args))
        self.assertTrue(first['committed'] and replay['replayed'])
        self.assertEqual(len(self.helper.writes), 1)
        self.assertEqual(len(self.gate.calls), 1)
        other_args = copy.deepcopy(args)
        other_args['arguments']['title'] = 'A different change'
        other_service = self.args('team_chat', operation_id=args['operation_id'])
        for changed in (other_args, other_service):
            with self.assertRaises(ZoomError) as caught:
                self.reopen().write(changed)
            self.assertEqual(caught.exception.state, 'operation_conflict')
        self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'another-account-connection'}))
        with self.assertRaises(ZoomError) as caught:
            self.reopen().write(args)
        self.assertEqual(caught.exception.state, 'operation_conflict')
        self.assertEqual(len(self.helper.writes), 1)
        path = self.data / 'zoom-doc-operations.sqlite'
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        content = path.read_bytes()
        self.assertNotIn(b'do-not-persist-this-secret', content)
        self.assertNotIn(b'Private fixture task', content, 'The journal must not store the submitted private body')

    def test_unknown_timeout_and_empty_ack_cannot_replay_after_restart(self):
        for index, (failure, ack) in enumerate([(ZoomError('timeout', 'Private fixture timeout'), None), (None, {}),
                             (None, {'data': {'request_id': 'transport-only-tracking'}})]):
            with self.subTest(failure=failure, ack=ack):
                self.helper.fail, self.helper.ack = failure, ack
                args = self.args('team_chat')
                args['arguments']['message_content'] += ' Case ' + str(index)
                before = len(self.helper.writes)
                for connector in (self.zoom, self.reopen()):
                    with self.assertRaises(ZoomError) as caught:
                        connector.write(args)
                    self.assertEqual(caught.exception.state, 'outcome_unknown')
                self.assertEqual(len(self.helper.writes), before + 1,
                                 'An uncertain send must never be repeated just to obtain confirmation')

    def test_unknown_send_cannot_be_disguised_with_a_new_operation_id(self):
        args = self.args('team_chat')
        self.helper.fail = ZoomError('timeout', 'The provider acknowledgement was lost')
        with self.assertRaises(ZoomError) as caught:
            self.zoom.write(args)
        self.assertEqual(caught.exception.state, 'outcome_unknown')
        self.helper.fail = None
        for _ in range(2):
            args['operation_id'] = str(uuid.uuid4())
            with self.assertRaises(ZoomError) as caught:
                self.reopen().write(args)
            self.assertEqual(caught.exception.state, 'outcome_unknown')
        self.assertEqual(len(self.helper.writes), 1)
        self.assertEqual(len(self.gate.calls), 1)

    def test_denied_and_mutated_approval_do_not_submit_or_reprompt_the_same_operation(self):
        self.gate.deny = True
        args = self.args('mail')
        for connector in (self.zoom, self.reopen()):
            with self.assertRaises(ZoomError) as caught:
                connector.write(args)
            self.assertEqual(caught.exception.state, 'denied')
        self.assertEqual(len(self.gate.calls), 1)
        self.assertFalse(self.helper.writes)
        self.gate.deny = False
        self.gate.on_ask = lambda action, _: action['arguments'].update(to=['different@example.invalid'])
        with self.assertRaises(ZoomError) as caught:
            self.zoom.write(self.args('mail'))
        self.assertEqual(caught.exception.state, 'invalid_approval')
        self.assertFalse(self.helper.writes)

    def test_schema_validation_and_unavailable_tools_fail_before_gate_or_commit(self):
        invalid = [self.args(arguments={}), self.args(arguments={'title': 'X', 'unknown': 'unreviewed'}),
                   self.args(arguments={'title': 'X', 'skip_notifications': 'yes'}),
                   self.args('meeting', arguments={'topic': 'X', 'duration': True, 'start_time_local': 'tomorrow'}),
                   self.args('team_chat', arguments={'chat_session_id': 'x', 'message_content': 'x' * 3201})]
        for args in invalid:
            with self.subTest(arguments=args['arguments']):
                with self.assertRaises(ZoomError):
                    self.zoom.write(args)
        self.helper.missing_tools.add('mcp_send_message')
        with self.assertRaises(ZoomError):
            self.reopen().write(self.args('mail'))
        self.assertFalse(self.gate.calls)
        self.assertFalse(self.helper.writes)

    def test_connection_or_conversation_change_after_approval_blocks_commit(self):
        for change in ('disconnect', 'new_connection', 'new_message'):
            with self.subTest(change=change):
                self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'private-connection'}))
                self.gate = Gate()
                self.zoom = self.reopen()
                def changed(_action, _context):
                    if change == 'disconnect':
                        self.settings.write_text(json.dumps({'enabled': False, 'connection_id': 'private-connection'}))
                    elif change == 'new_connection':
                        self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'new-connection'}))
                    else:
                        self.gate.invalidate_pending()
                self.gate.on_ask = changed
                with self.assertRaises(ValueError):
                    self.zoom.write(self.args())
                self.assertFalse(self.helper.writes)

    def test_generation_changes_after_claim_are_blocked_at_the_last_commit_check(self):
        checks = 0
        def changed_at_commit():
            nonlocal checks
            checks += 1
            if checks == 3:  # ask(), pre-claim and the final pre-dispatch check
                self.gate.invalidate_pending()
        self.gate.execution_check = changed_at_commit
        args = self.args()
        with self.assertRaises(ValueError):
            self.zoom.write(args)
        self.assertEqual(checks, 3)
        self.assertFalse(self.helper.writes)
        with self.assertRaises(ZoomError) as caught:
            self.reopen().write(args)
        self.assertEqual(caught.exception.state, 'superseded')
        self.assertEqual(len(self.gate.calls), 1)

    def test_committed_but_wrong_or_unavailable_readback_is_not_resubmitted(self):
        for mode in ('permission', 'wrong_field', 'wrong_resource'):
            with self.subTest(mode=mode):
                self.helper.read_failure = ZoomError('permission_denied', 'Fixture read denied') if mode == 'permission' else None
                self.helper.read_overrides = {}
                if mode != 'permission':
                    self.helper.read_overrides['tasks_get'] = {'data': {'id': 'other-resource' if mode == 'wrong_resource' else 'synthetic-tasks',
                                                                      'task_id': 'other-resource' if mode == 'wrong_resource' else 'synthetic-tasks',
                                                                      'title': 'Wrong title' if mode == 'wrong_field' else 'Private fixture task'}}
                args = self.args(verify=True)
                before = len(self.helper.writes)
                result = self.zoom.write(args)
                self.assertTrue(result['committed'])
                self.assertFalse(result['verified'])
                replay = self.reopen().write(args)
                self.assertTrue(replay['replayed'])
                self.assertEqual(len(self.helper.writes), before + 1)

    def test_readback_cannot_be_a_mutation_and_mismatched_resource_is_not_verified(self):
        args = self.args(verify=True)
        args['verification']['tool'] = 'tasks_create'
        args['verification']['arguments'] = {'title': 'An unintended extra task'}
        with self.assertRaises(ZoomError):
            self.zoom.write(args)
        self.assertFalse(self.helper.writes)
        self.assertFalse(self.gate.calls)
        args = self.args(verify=True)
        args['verification']['arguments']['taskId'] = 'another-task'
        result = self.zoom.write(args)
        self.assertTrue(result['committed'])
        self.assertFalse(result['verified'], 'Matching text in a different resource must not verify this write')
        self.assertEqual(len(self.helper.writes), 1)

    def test_missing_resource_id_and_quoted_old_text_do_not_verify_automatic_readback(self):
        for payload in ({'title': 'Private fixture task'},
                        {'id': 'synthetic-tasks', 'title': 'Not the new title',
                         'quoted_previous_task': {'title': 'Private fixture task'}}):
            with self.subTest(payload=payload):
                self.helper.read_overrides['tasks_get'] = {'data': payload}
                result = self.zoom.write(self.args())
                self.assertTrue(result['committed'])
                self.assertFalse(result['verified'])

    def test_false_result_cannot_be_hidden_by_a_successful_transport_wrapper(self):
        self.helper.ack = {'status': True, 'data': False}
        args = self.args('team_chat')
        for connector in (self.zoom, self.reopen()):
            with self.assertRaises(ZoomError) as caught:
                connector.write(args)
            self.assertEqual(caught.exception.state, 'outcome_unknown')
        self.assertEqual(len(self.helper.writes), 1)

    def test_explicit_fields_must_be_changed_values_and_match_exact_scalar_types(self):
        for expected, actual in [('An old unrelated title', 'An old unrelated title'),
                                 ('Private fixture task', 'Private fixture task, with extra words'),
                                 (True, 1)]:
            with self.subTest(expected=expected, actual=actual):
                args = self.args(verify=True)
                args['verification']['expected_fields'] = {'data.title': expected}
                self.helper.read_overrides['tasks_get'] = {'data': {'id': 'synthetic-tasks', 'title': actual}}
                result = self.zoom.write(args)
                self.assertTrue(result['committed'])
                self.assertFalse(result['verified'])

    def test_verification_reads_fresh_content_instead_of_cached_old_success(self):
        args = self.args(verify=True)
        before = self.zoom.read({key: args['verification'][key] for key in ('service', 'tool', 'arguments')})
        self.assertEqual(before['result']['data']['title'], 'Private fixture task')
        reads = sum(call[:2] == ['tasks', 'tasks_get'] for call in self.helper.calls)
        self.helper.read_overrides['tasks_get'] = {'data': {'id': 'synthetic-tasks', 'title': 'A newer conflicting value'}}
        result = self.zoom.write(args)
        self.assertTrue(result['committed'])
        self.assertFalse(result['verified'])
        self.assertEqual(sum(call[:2] == ['tasks', 'tasks_get'] for call in self.helper.calls), reads + 1)

    def test_generic_write_has_no_implicit_authorization_without_a_task_gate(self):
        self.zoom.gate = None
        with self.assertRaises(ZoomError) as caught:
            self.zoom.write(self.args('mail'))
        self.assertEqual(caught.exception.state, 'approval_unavailable')
        self.assertFalse(self.helper.writes)
        self.assertFalse(self.gate.calls)

    def test_sheet_schema_correction_is_documented_narrow_and_preserves_raw_contract(self):
        self.sheet_contract()
        raw = copy.deepcopy(self.helper.schema_overrides['sheets_edit_cells'])
        metadata = self.zoom.schema({'service': 'sheets', 'tool': 'sheets_edit_cells'})
        self.assertEqual(metadata['raw_input_schema'], raw)
        self.assertIn('compatibility_note', metadata)
        for path in (('cellValues', 'items'), ('appendRows', None)):
            node = metadata['inputSchema']['properties'][path[0]]
            if path[1]:
                node = node[path[1]]
            leaf = node['properties']['values']['items']['items']
            self.assertEqual(set(leaf['type']), {'string', 'number', 'boolean', 'null'})
        untouched = metadata['inputSchema']['properties']['cellFormats']['items']['properties']['format']
        self.assertEqual(untouched['type'], 'object', 'A matching description outside the two audited paths must not relax object validation')
        self.assertEqual(self.helper.schema_overrides['sheets_edit_cells'], raw)

    def test_sheet_literal_and_append_values_accept_primitives_but_reject_nested_objects(self):
        self.sheet_contract()
        rows = [['text', 7, 2.5, True, None]]
        for key in ('cellValues', 'appendRows'):
            with self.subTest(key=key):
                args = self.args('sheets', arguments={'sheetId': 'private-sheet', 'worksheetId': 'private-worksheet',
                    key: [{'range': 'A1', 'values': rows}] if key == 'cellValues' else {'values': rows}})
                result = self.zoom.write(args)
                self.assertTrue(result['committed'])
                self.assertEqual(self.helper.writes[-1][2], args['arguments'])
                before = len(self.gate.calls), len(self.helper.writes)
                args['operation_id'] = str(uuid.uuid4())
                if key == 'cellValues':
                    args['arguments'][key][0]['values'] = [[{'stringValue': 'not a primitive'}]]
                else:
                    args['arguments'][key]['values'] = [[{'numberValue': 7}]]
                with self.assertRaises(ZoomError):
                    self.zoom.write(args)
                self.assertEqual((len(self.gate.calls), len(self.helper.writes)), before)
        before = len(self.gate.calls), len(self.helper.writes)
        with self.assertRaises(ZoomError):
            self.zoom.write(self.args('sheets', arguments={'sheetId': 'private-sheet', 'worksheetId': 'private-worksheet',
                                                          'cellFormats': [{'format': 'still requires an object'}]}))
        self.assertEqual((len(self.gate.calls), len(self.helper.writes)), before)

    def test_sheet_scalar_correction_does_not_relax_nonempty_object_or_undocumented_schema(self):
        for changed in ('nonempty_object', 'undocumented'):
            with self.subTest(changed=changed):
                raw = conflicting_sheet_schema()
                leaf = raw['properties']['cellValues']['items']['properties']['values']['items']['items']
                if changed == 'nonempty_object':
                    leaf['properties'] = {'value': STRING}
                else:
                    leaf['description'] = 'A structured cell object.'
                self.helper.schema_overrides['sheets_edit_cells'] = raw
                with self.assertRaises(ZoomError):
                    self.reopen().write(self.args('sheets'))
                self.assertFalse(self.helper.writes)
                self.assertFalse(self.gate.calls)

    def test_sheet_literal_ranges_shapes_and_unknown_group_fields_fail_before_submission(self):
        self.sheet_contract()
        invalid_groups = [
            {'range': 'A1', 'values': []}, {'range': 'A1', 'values': [[]]},
            {'range': 'A1', 'values': [[1, 2], [3]]},
            {'range': 'A1:B2', 'values': [[1]]}, {'range': 'B2:A1', 'values': [[1]]},
            {'range': 'A:C', 'values': [[1]]}, {'range': 'A0', 'values': [[1]]},
            {'range': 'Sheet1!A1', 'values': [[1]]},
            {'range': 'A1', 'values': [[1]], 'unreviewed': True}]
        for group in invalid_groups:
            with self.subTest(group=group):
                with self.assertRaises(ZoomError):
                    self.zoom.write(self.args('sheets', arguments={'sheetId': 'private-sheet', 'worksheetId': 'private-worksheet', 'cellValues': [group]}))
        for appended in ({'values': []}, {'values': [[]]}, {'values': [[1, 2], [3]]}, {'values': [[1]], 'unreviewed': True}):
            with self.subTest(appended=appended):
                with self.assertRaises(ZoomError):
                    self.zoom.write(self.args('sheets', arguments={'sheetId': 'private-sheet', 'worksheetId': 'private-worksheet', 'appendRows': appended}))
        self.assertFalse(self.helper.writes)
        self.assertFalse(self.gate.calls)

    def test_sheet_automatic_readback_requires_exact_target_range_complete_values_and_types(self):
        self.sheet_contract()
        rows = [[1, True, None], ['text', 2.5, '']]
        correct = {'worksheetId': 'private-worksheet', 'range': 'B2:D3',
                   'truncated': False, 'nextPageToken': '', 'compact': {'values': rows}}
        cases = [('correct', correct)]
        for mode in ('worksheet', 'range', 'type', 'null', 'truncated', 'nextPageToken', 'sheetId'):
            payload = copy.deepcopy(correct)
            if mode == 'worksheet': payload['worksheetId'] = 'different-tab'
            elif mode == 'range': payload['range'] = 'B3:D4'
            elif mode == 'type': payload['compact']['values'][0][0] = True
            elif mode == 'null': payload['compact']['values'][0][2] = ''
            elif mode == 'truncated': payload['truncated'] = True
            elif mode == 'nextPageToken': payload['nextPageToken'] = 'more-service-rows'
            else: payload['sheetId'] = 'different-sheet'
            cases.append((mode, payload))
        for mode, payload in cases:
            with self.subTest(mode=mode):
                self.helper.read_overrides['sheets_read_cells'] = {'data': payload}
                result = self.zoom.write(self.args('sheets', arguments={'sheetId': 'private-sheet', 'worksheetId': 'private-worksheet',
                    'cellValues': [{'range': 'b2', 'values': rows}]}))
                self.assertTrue(result['committed'])
                self.assertEqual(result['verified'], mode == 'correct', result)
                read = next(call for call in reversed(self.helper.calls) if call[:2] == ['sheets', 'sheets_read_cells'])
                self.assertEqual(json.loads(read[-1]), {'sheetId': 'private-sheet', 'worksheetId': 'private-worksheet',
                    'range': 'B2:D3', 'include': 'values', 'pageSize': 2})

    def test_sheet_appends_and_multiple_regions_do_not_claim_automatic_cell_readback(self):
        self.sheet_contract()
        for changes in ({'appendRows': {'values': [['text', 1]]}},
                        {'cellValues': [{'range': 'A1', 'values': [[1]]}, {'range': 'C1', 'values': [[2]]}]},
                        {'cellValues': [{'range': 'A1', 'values': [[1]]}], 'appendRows': {'values': [[2]]}}):
            with self.subTest(changes=changes):
                before = sum(call[:2] == ['sheets', 'sheets_read_cells'] for call in self.helper.calls)
                result = self.zoom.write(self.args('sheets', arguments={'sheetId': 'private-sheet', 'worksheetId': 'private-worksheet', **changes}))
                self.assertTrue(result['committed'])
                self.assertFalse(result['verified'])
                self.assertEqual(sum(call[:2] == ['sheets', 'sheets_read_cells'] for call in self.helper.calls), before)

    def test_create_sheet_populates_scalar_literals_and_formula_strings_under_exact_schema(self):
        self.sheet_contract()
        metadata = self.zoom.schema({'service': 'sheets', 'tool': 'sheets_create_spreadsheet'})
        raw = self.helper.schema_overrides['sheets_create_spreadsheet']
        self.assertEqual(metadata['raw_input_schema'], raw)
        normalized = metadata['inputSchema']['properties']['sheets']['items']['properties']
        self.assertEqual(set(normalized['cellValues']['items']['properties']['values']['items']['items']['type']),
                         {'string', 'number', 'boolean', 'null'})
        formula = normalized['cellFormulas']['items']['properties']['formulas']['items']['items']
        self.assertEqual(formula['type'], 'string')
        self.assertEqual(formula['pattern'], '^=')
        self.assertEqual(normalized['cellFormats']['items']['properties']['format']['type'], 'object')
        arguments = {'fileName': 'Private created workbook', 'sheets': [{'name': 'Overview',
            'cellValues': [{'range': 'A1:E1', 'values': [['label', 1, 2.5, True, None]]}],
            'cellFormulas': [{'range': 'F1', 'formulas': [['=SUM(B1:C1)']]}]}]}
        result = self.zoom.write(self.args('sheets', tool='sheets_create_spreadsheet', arguments=arguments))
        self.assertTrue(result['committed'])
        self.assertFalse(result['verified'])
        self.assertEqual(self.helper.writes[0], ('sheets', 'sheets_create_spreadsheet', arguments))

    def test_create_and_edit_sheet_formulas_reject_nonformula_cells_shapes_and_unknown_group_keys(self):
        self.sheet_contract()
        valid = {'range': 'B1:B2', 'formulas': [['=A1*2'], ['=A2*2']]}
        result = self.zoom.write(self.args('sheets', arguments={'sheetId': 'private-sheet', 'worksheetId': 'private-worksheet', 'cellFormulas': [valid]}))
        self.assertTrue(result['committed'])
        invalid = [{'range': 'B1', 'formulas': [[7]]}, {'range': 'B1', 'formulas': [[{'stringValue': '=A1'}]]},
                   {'range': 'B1', 'formulas': [['SUM(A1:A3)']]}, {'range': 'B1', 'formulas': [[None]]},
                   {'range': 'B1:B3', 'formulas': [['=A1'], ['=A2']]},
                   {'range': 'B1', 'formulas': [['=A1']], 'unreviewed': True}]
        before = len(self.gate.calls), len(self.helper.writes)
        for tool in ('sheets_create_spreadsheet', 'sheets_edit_cells'):
            for group in invalid:
                with self.subTest(tool=tool, group=group):
                    arguments = ({'fileName': 'Invalid workbook', 'sheets': [{'cellFormulas': [group]}]}
                                 if tool == 'sheets_create_spreadsheet' else
                                 {'sheetId': 'private-sheet', 'worksheetId': 'private-worksheet', 'cellFormulas': [group]})
                    with self.assertRaises(ZoomError):
                        self.zoom.write(self.args('sheets', tool=tool, arguments=arguments))
                    self.assertEqual((len(self.gate.calls), len(self.helper.writes)), before)
        for group in ({'range': 'A1:B2', 'values': [[1]]}, {'range': 'A1', 'values': [[{'value': 'object'}]]},
                      {'range': 'A1', 'values': [[1]], 'unreviewed': True}):
            with self.subTest(create_literal=group):
                with self.assertRaises(ZoomError):
                    self.zoom.write(self.args('sheets', tool='sheets_create_spreadsheet',
                        arguments={'sheets': [{'cellValues': [group]}]}))
                self.assertEqual((len(self.gate.calls), len(self.helper.writes)), before)

    def test_explicit_sheet_readback_is_bound_to_written_range_and_each_expected_coordinate(self):
        self.sheet_contract()
        rows = [[10, 20]]
        cases = [('correct', 'A1:B1', 'A1:B1', {'data.compact.values.0.0': 10}, [[10, 20]]),
                 ('different_read_range', 'C1:D1', 'C1:D1', {'data.compact.values.0.0': 10}, [[10, 20]]),
                 ('different_returned_range', 'A1:B1', 'C1:D1', {'data.compact.values.0.0': 10}, [[10, 20]]),
                 ('swapped_coordinate', 'A1:B1', 'A1:B1', {'data.compact.values.0.0': 20}, [[20, 10]]),
                 ('service_truncated', 'A1:B1', 'A1:B1', {'data.compact.values.0.0': 10}, [[10, 20]]),
                 ('service_cursor', 'A1:B1', 'A1:B1', {'data.compact.values.0.0': 10}, [[10, 20]])]
        for mode, requested_range, returned_range, expected, read_rows in cases:
            with self.subTest(mode=mode):
                request = self.args('sheets', arguments={'sheetId': 'private-sheet', 'worksheetId': 'private-worksheet',
                    'cellValues': [{'range': 'A1:B1', 'values': rows}]})
                request['verification'] = {'service': 'sheets', 'tool': 'sheets_read_cells',
                    'arguments': {'sheetId': 'private-sheet', 'worksheetId': 'private-worksheet', 'range': requested_range},
                    'expected_fields': expected}
                self.helper.read_overrides['sheets_read_cells'] = {'data': {'worksheetId': 'private-worksheet',
                    'range': returned_range, 'compact': {'values': read_rows}, 'truncated': mode == 'service_truncated',
                    'nextPageToken': 'more-rows' if mode == 'service_cursor' else ''}}
                result = self.zoom.write(request)
                self.assertTrue(result['committed'])
                self.assertEqual(result['verified'], mode == 'correct', result)

    def test_explicit_readback_cannot_use_another_submitted_field_or_a_quoted_old_body(self):
        self.helper.schema_overrides['tasks_create'] = schema({'title': STRING, 'description': STRING}, ['title'])
        request = self.args(arguments={'title': 'Intended new title', 'description': 'Unrelated old title'}, verify=True)
        request['verification']['expected_fields'] = {'data.title': 'Unrelated old title'}
        self.helper.read_overrides['tasks_get'] = {'data': {'id': 'synthetic-tasks', 'title': 'Unrelated old title'}}
        result = self.zoom.write(request)
        self.assertTrue(result['committed'])
        self.assertFalse(result['verified'], 'A value submitted for description must not establish the new title')
        for path, payload in [('data.content.quote.text', {'content': {'quote': {'text': 'Private fixture conversation.'}}}),
                              ('data.quote.text', {'quote': {'text': 'Private fixture conversation.'}})]:
            with self.subTest(path=path):
                request = self.args('team_chat', verify=True)
                request['verification']['expected_fields'] = {path: 'Private fixture conversation.'}
                self.helper.read_overrides['team_chat_msg_get_by_id'] = {'data': dict(payload,
                    message_id='synthetic-team_chat', chat_session_id='private-session')}
                result = self.zoom.write(request)
                self.assertTrue(result['committed'])
                self.assertFalse(result['verified'])

    def test_sheet_edit_specific_versioned_affected_cells_ack_is_not_guessed_for_other_payloads(self):
        for index, ack in enumerate(({'affectedCells': 2, 'affectedRanges': ['A1:B1'], 'version': 3},
                                    {'affectedCells': True, 'affectedRanges': ['A1:B1'], 'version': 3},
                                    {'affectedCells': 2, 'affectedRanges': ['A1:B1'], 'version': True},
                                    {'affectedCells': -1, 'affectedRanges': ['A1:B1'], 'version': 3},
                                    {'affectedCells': 2, 'affectedRanges': ['A1:B1'], 'version': -1},
                                    {'affectedCells': 2, 'affectedRanges': ['A1:B1']},
                                    {'success': False, 'affectedCells': 2, 'affectedRanges': ['A1:B1'], 'version': 3},
                                    {'status': True, 'data': False})):
            with self.subTest(ack=ack):
                self.helper.ack = ack
                request = self.args('sheets')
                request['arguments']['cellValues'][0]['values'][0][0] += ' Ack case ' + str(index)
                if index == 0:
                    result = self.zoom.write(request)
                    self.assertTrue(result['committed'])
                else:
                    with self.assertRaises(ZoomError) as caught:
                        self.zoom.write(request)
                    self.assertEqual(caught.exception.state, 'outcome_unknown')
                before = len(self.helper.writes)
                if index:
                    with self.assertRaises(ZoomError):
                        self.reopen().write(request)
                    self.assertEqual(len(self.helper.writes), before)

    def test_task_update_empty_ack_can_be_proven_by_fresh_changed_fields_and_exact_task_id(self):
        self.task_update_contract()
        request = self.task_update()
        current = dict(request['arguments'], id='synthetic-tasks')
        before = dict(current, title='Old title', status='To do', starred=False)
        self.helper.read_sequences['tasks_get'] = [{'data': before}, {'data': current}]
        self.helper.fail = ZoomError('empty_response', 'Exact synthetic gateway empty response')
        result = self.zoom.write(request)
        self.assertTrue(result['committed'] and result['verified'])
        self.assertFalse(result['provider_acknowledged'])
        self.assertEqual(result['commit_evidence'], 'changed_fields_fresh_readback')
        self.assertEqual(result['verification'], 'verified_after_empty_response')
        self.assertEqual(result['verification_scope'], 'all_submitted_task_fields')
        self.assertEqual(set(result['read_back']['matched_fields']), set(request['arguments']) - {'taskId'})
        self.assertEqual(self.helper.writes, [('tasks', 'task_update', request['arguments'])])
        self.assertEqual(sum(call[:2] == ['tasks', 'tasks_get'] for call in self.helper.calls), 2)
        self.assertTrue(self.reopen().write(request)['replayed'])
        self.assertEqual(len(self.helper.writes), 1)

    def test_task_update_does_not_infer_commit_without_complete_before_after_or_exact_empty_error(self):
        self.task_update_contract()
        for mode in ('unchanged', 'before_missing_field', 'before_unavailable', 'wrong_before_id',
                     'wrong_after_id', 'after_missing_field', 'other_error', 'cancelled', 'changed_connection', 'future_field'):
            with self.subTest(mode=mode):
                self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'private-connection'}))
                request = self.task_update()
                request['arguments']['title'] += ' Case ' + mode
                if mode == 'future_field':
                    self.helper.schema_overrides['task_update']['properties']['future_persistent_field'] = STRING
                    request['arguments']['future_persistent_field'] = 'This new field cannot use an old verification whitelist'
                current = dict(request['arguments'], id='synthetic-tasks')
                before = dict(current, title='Old title')
                after = copy.deepcopy(current)
                if mode == 'unchanged': before = copy.deepcopy(current)
                elif mode == 'before_missing_field': before.pop('starred')
                elif mode == 'before_unavailable': before = ZoomError('permission_denied', 'Fixture cannot read before')
                elif mode == 'wrong_before_id': before.update(id='other-task', taskId='other-task')
                elif mode == 'wrong_after_id': after.update(id='other-task', taskId='other-task')
                elif mode == 'after_missing_field': after.pop('starred')
                self.helper.read_sequences['tasks_get'] = [before if isinstance(before, Exception) else {'data': before}, {'data': after}]
                self.helper.fail = ZoomError('unavailable' if mode == 'other_error' else 'empty_response', 'Synthetic task update failure')
                def after_write(_service, _tool, _values):
                    if mode == 'cancelled': self.gate.invalidate_pending()
                    elif mode == 'changed_connection': self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'another-connection'}))
                self.helper.after_write = after_write
                count = len(self.helper.writes)
                with self.assertRaises(ZoomError) as caught:
                    self.reopen().write(request)
                self.assertEqual(caught.exception.state, 'outcome_unknown')
                self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'private-connection'}))
                with self.assertRaises(ZoomError) as caught:
                    self.reopen().write(request)
                self.assertEqual(caught.exception.state, 'outcome_unknown')
                request['operation_id'] = str(uuid.uuid4())
                with self.assertRaises(ZoomError) as caught:
                    self.reopen().write(request)
                self.assertEqual(caught.exception.state, 'outcome_unknown')
                self.assertEqual(len(self.helper.writes), count + 1)

    def test_task_update_rechecks_generation_after_before_and_after_reads(self):
        self.task_update_contract()
        for changed_at in ('before_read', 'after_read'):
            with self.subTest(changed_at=changed_at):
                request = self.task_update()
                request['arguments']['title'] += ' ' + changed_at
                current = dict(request['arguments'], id='synthetic-tasks')
                self.helper.read_sequences['tasks_get'] = [{'data': dict(current, title='Old title')}, {'data': current}]
                self.helper.fail = ZoomError('empty_response', 'Exact synthetic gateway empty response')
                writes = len(self.helper.writes)
                def during_read():
                    if (changed_at == 'before_read' and len(self.helper.writes) == writes
                            or changed_at == 'after_read' and len(self.helper.writes) > writes):
                        self.gate.invalidate_pending()
                self.helper.before_read = during_read
                with self.assertRaises((ValueError, ZoomError)):
                    self.reopen().write(request)
                self.assertEqual(len(self.helper.writes), writes + (changed_at == 'after_read'))

    def test_team_chat_native_nested_session_and_content_verify_the_actual_message(self):
        self.helper.read_overrides['team_chat_msg_get_by_id'] = self.native_chat_message('private-session')
        result = self.zoom.write(self.args('team_chat'))
        self.assertTrue(result['committed'] and result['verified'], result)
        self.assertEqual(len(self.helper.writes), 1)

    def test_team_chat_email_resolution_uses_fresh_unique_evidence_without_changing_send_authorization(self):
        email, identity = 'person@example.invalid', 'Unique-UID-CaseSensitive'
        self.team_chat_contacts_contract([{'userId': identity, 'email': 'PERSON@example.invalid', 'fullName': 'Private fixture'}])
        request = self.args('team_chat')
        request['arguments']['chat_session_id'] = email
        self.helper.read_overrides['team_chat_msg_get_by_id'] = self.native_chat_message(identity)
        result = self.zoom.write(request)
        self.assertTrue(result['committed'] and result['verified'], result)
        self.assertEqual(self.helper.writes, [('team_chat', 'team_chat_msg_send', request['arguments'])])
        self.assertEqual(self.gate.calls[0][0]['arguments']['chat_session_id'], email)
        lookups = [call for call in self.helper.calls if call[:2] == ['contact', 'contacts_search']]
        self.assertEqual(len(lookups), 1)
        self.assertEqual(json.loads(lookups[0][-1]), {'keyword': email, 'fieldsMode': 'minimal', 'from': 0, 'limit': 100})
        read = next(call for call in reversed(self.helper.calls) if call[:2] == ['team_chat', 'team_chat_msg_get_by_id'])
        self.assertEqual(json.loads(read[-1]), {'message_id': 'synthetic-team_chat', 'chat_session_id': identity})
        before = len(self.helper.calls)
        self.assertTrue(self.reopen().write(request)['replayed'])
        self.assertEqual(len(self.helper.calls), before, 'A completed operation lookup must not repeat a send or identity search')

    def test_team_chat_email_proof_rejects_other_or_ambiguous_contacts_and_wrong_actual_session(self):
        email, identity = 'person@example.invalid', 'Unique-UID-CaseSensitive'
        for mode in ('different_email', 'ambiguous_email', 'wrong_session', 'wrong_uid_case', 'quoted_correct_session',
                     'quoted_correct_message', 'quoted_correct_content', 'correct_sender_wrong_session', 'wrong_typed_session_type'):
            with self.subTest(mode=mode):
                rows = [{'userId': identity, 'email': email}]
                if mode == 'different_email': rows[0]['email'] = 'other-person@example.invalid'
                elif mode == 'ambiguous_email': rows.append({'userId': 'second-user-with-same-email', 'email': email})
                self.team_chat_contacts_contract(rows)
                message = self.native_chat_message(identity)
                if mode == 'wrong_session': message['data']['chat_session']['id'] = 'different-actual-session'
                elif mode == 'wrong_uid_case': message['data']['chat_session']['id'] = identity.lower()
                elif mode == 'quoted_correct_session':
                    message['data']['chat_session']['id'] = 'different-actual-session'
                    message['data']['quote'] = {'chat_session': {'id': identity}}
                elif mode == 'quoted_correct_message':
                    message['data']['message_id'] = 'different-actual-message'
                    message['data']['quote'] = {'message_id': 'synthetic-team_chat'}
                elif mode == 'quoted_correct_content':
                    message['data']['content'] = 'An old unrelated message body'
                    message['data']['quote'] = {'content': 'Private fixture conversation.'}
                elif mode == 'correct_sender_wrong_session':
                    message['data']['chat_session']['id'] = 'different-actual-session'
                    message['data']['sender']['user_id'] = identity
                elif mode == 'wrong_typed_session_type':
                    message['data']['chat_session']['type'] = 'channel'
                self.helper.read_overrides['team_chat_msg_get_by_id'] = message
                request = self.args('team_chat')
                request['arguments']['chat_session_id'] = email
                result = self.reopen().write(request)
                self.assertTrue(result['committed'])
                self.assertFalse(result['verified'], result)
                self.assertEqual(self.helper.writes[-1][2]['chat_session_id'], email)

    def test_team_chat_identity_aliases_do_not_leak_between_operations_or_globally_ignore_id_case(self):
        email, identity = 'person@example.invalid', 'Unique-UID-CaseSensitive'
        self.team_chat_contacts_contract([{'userId': identity, 'email': email}])
        first = self.args('team_chat')
        first['arguments']['chat_session_id'] = email
        self.helper.read_overrides['team_chat_msg_get_by_id'] = self.native_chat_message(identity)
        self.assertTrue(self.zoom.write(first)['verified'])
        later = self.args('team_chat')
        later['arguments']['chat_session_id'] = identity.lower()
        result = self.zoom.write(later)
        self.assertTrue(result['committed'])
        self.assertFalse(result['verified'], 'A proven email mapping from a different operation cannot make all opaque IDs case-insensitive')
        later = self.args('team_chat')
        later['arguments']['chat_session_id'] = 'private-session'
        self.helper.read_overrides['team_chat_msg_get_by_id'] = self.native_chat_message('PRIVATE-SESSION')
        self.assertFalse(self.zoom.write(later)['verified'])

    def test_team_chat_email_mapping_does_not_reuse_a_cached_contact_search(self):
        email, identity = 'person@example.invalid', 'Unique-UID-CaseSensitive'
        self.team_chat_contacts_contract([{'userId': identity, 'email': email}])
        self.zoom.read({'service': 'contact', 'tool': 'contacts_search', 'arguments': {'keyword': email}})
        self.helper.read_overrides['contacts_search'] = {'users': [{'userId': identity, 'email': 'other-person@example.invalid'}], 'totalCount': 1}
        self.helper.read_overrides['team_chat_msg_get_by_id'] = self.native_chat_message(identity)
        request = self.args('team_chat')
        request['arguments']['chat_session_id'] = email
        result = self.zoom.write(request)
        self.assertTrue(result['committed'])
        self.assertFalse(result['verified'])
        self.assertEqual(sum(call[:2] == ['contact', 'contacts_search'] for call in self.helper.calls), 2)

    def test_team_chat_email_mapping_deduplicates_one_identity_but_requires_complete_evidence(self):
        email, identity = 'person@example.invalid', 'Unique-UID-CaseSensitive'
        for mode in ('same_uid_duplicates', 'partial_page', 'case_distinct_uids'):
            with self.subTest(mode=mode):
                rows = [{'userId': identity, 'email': email}]
                if mode == 'same_uid_duplicates': rows.append(copy.deepcopy(rows[0]))
                elif mode == 'case_distinct_uids': rows.append({'userId': identity.lower(), 'email': email})
                self.team_chat_contacts_contract(rows)
                if mode == 'partial_page': self.helper.read_overrides['contacts_search']['totalCount'] = len(rows) + 1
                self.helper.read_overrides['team_chat_msg_get_by_id'] = self.native_chat_message(identity)
                request = self.args('team_chat')
                request['arguments']['chat_session_id'] = email
                result = self.reopen().write(request)
                self.assertTrue(result['committed'])
                self.assertEqual(result['verified'], mode == 'same_uid_duplicates', result)

    def test_team_chat_id_case_alias_requires_fresh_unambiguous_same_account_direct_session_metadata(self):
        email, identity, account = 'person@example.invalid', 'Unique-UID-CaseSensitive', 'private-account'
        for mode in ('proved_alias', 'wrong_account', 'wrong_session_type', 'ambiguous_metadata', 'different_uid_stem'):
            with self.subTest(mode=mode):
                self.team_chat_contacts_contract([{'userId': identity, 'email': email, 'accountId': account}])
                self.helper.schema_overrides['team_chat_session_metadata_fetch'] = schema({'chat_session_id': {
                    'type': 'object', 'properties': {}, 'description':
                    'Accepts either a single string or an array of up to 10 strings.'}}, ['chat_session_id'])
                row = {'chat_session_id': identity.lower(), 'chat_session_counterpart_jid': identity.lower(),
                       'chat_session_counterpart_account_id': account, 'chat_session_type': 'direct_chat'}
                if mode == 'wrong_account': row['chat_session_counterpart_account_id'] = 'different-account'
                elif mode == 'wrong_session_type': row['chat_session_type'] = 'channel'
                elif mode == 'different_uid_stem':
                    row['chat_session_id'] = row['chat_session_counterpart_jid'] = 'different-user'
                rows = [row, copy.deepcopy(row)] if mode == 'ambiguous_metadata' else [row]
                self.helper.read_overrides['team_chat_session_metadata_fetch'] = {'data': rows}
                self.helper.read_overrides['team_chat_msg_get_by_id'] = self.native_chat_message(identity.lower())
                request = self.args('team_chat')
                request['arguments']['chat_session_id'] = email
                result = self.reopen().write(request)
                self.assertTrue(result['committed'])
                self.assertEqual(result['verified'], mode == 'proved_alias', result)
                call = next(call for call in reversed(self.helper.calls) if call[:2] == ['team_chat', 'team_chat_session_metadata_fetch'])
                self.assertEqual(json.loads(call[-1]), {'chat_session_id': identity})


if __name__ == '__main__':
    unittest.main()
