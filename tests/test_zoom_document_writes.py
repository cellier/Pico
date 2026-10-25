import copy
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from zoom_connector import ZoomConnector, ZoomError, READ_TOOLS, WRITE_TOOLS
from register_zoom import register_zoom
from zoom_documents import xml_tree
from mac_bridge import ApprovalGate


def strings(*names):
    return {name: {'type': 'string'} for name in names}


SCHEMAS = {
    'docs_file_create_with_content': {'type': 'object', 'properties': strings('file_name', 'content', 'parent_id'), 'required': ['file_name']},
    'docs_file_insert_blocks': {'type': 'object', 'properties': dict(strings('file_id', 'blocks'), positioning={'type': 'object', 'properties': strings('above_block_id', 'below_block_id', 'parent_block_id')}), 'required': ['file_id', 'blocks']},
    'docs_file_update_block': {'type': 'object', 'properties': strings('file_id', 'block_id', 'block'), 'required': ['file_id', 'block_id', 'block']},
    'docs_file_replace_range_of_blocks': {'type': 'object', 'properties': strings('file_id', 'start_block_id', 'end_block_id', 'blocks'), 'required': ['file_id', 'start_block_id', 'end_block_id', 'blocks']},
    'docs_file_modify_metadata': {'type': 'object', 'properties': strings('id', 'file_name'), 'required': ['id']},
    'docs_file_get_content': {'type': 'object', 'properties': strings('file_id', 'format'), 'required': ['file_id']},
}
BASE = '<page block_id="page"><text block_id="first">Original paragraph</text><text block_id="last">Existing unique marker</text></page>'


class Gate:
    def __init__(self):
        self.calls = []
        self.deny = False
        self.on_ask = None

    def ask(self, action, context):
        self.calls.append((copy.deepcopy(action), copy.deepcopy(context)))
        if self.on_ask:
            self.on_ask(action, context)
        return None if self.deny else copy.deepcopy(action)


class Helper:
    def __init__(self):
        self.calls = []
        self.doc = {'content': BASE, 'file_name': 'Synthetic document', 'can_edit': True, 'file_link': 'https://docs.zoom.us/doc/synthetic'}
        self.after = None
        self.ack = {'success': True}
        self.fail = None
        self.fail_read_after_write = False
        self.writes = 0
        self.before_read = None

    def __call__(self, command):
        args = command[2:-1]
        self.calls.append(args)
        if args == ['docs']:
            return json.dumps([{'name': name} for name in READ_TOOLS['docs'] | WRITE_TOOLS['docs']])
        if args[1] == 'schema':
            return 'Input Schema:\n' + json.dumps(SCHEMAS.get(args[2], {'type': 'object', 'properties': {}}))
        tool, values = args[1], json.loads(args[-1])
        if tool == 'docs_file_get_content':
            if self.before_read:
                self.before_read()
            if self.writes and self.fail_read_after_write:
                raise ZoomError('permission_denied', 'Synthetic read failure')
            return json.dumps({'_tracking_id': uuid.uuid4().hex, 'data': self.doc})
        self.writes += 1
        if self.fail:
            raise self.fail
        if self.after:
            self.doc.update(self.after)
        result = self.ack
        if tool == 'docs_file_create_with_content' and result == {'success': True}:
            self.doc.update(file_name=values['file_name'], content='<page><text>' + values.get('content', '') + '</text></page>')
            result = {'file_id': 'created-doc', 'file_link': 'https://docs.zoom.us/doc/created-doc'}
        if tool == 'docs_file_modify_metadata' and self.after is None:
            self.doc['file_name'] = values['file_name']
        return json.dumps({'_tracking_id': 'synthetic', 'data': result})


class DocumentWriteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.data = Path(self.temp.name)
        self.settings = self.data / 'zoom-connection.json'
        self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'synthetic-connection'}))
        self.helper = Helper()
        self.gate = Gate()
        self.zoom = ZoomConnector(self.data, helper='/usr/bin/true', runner=self.helper, gate=self.gate)

    def tearDown(self):
        self.temp.cleanup()

    def args(self, tool='docs_file_create_with_content', **extra):
        arguments = {'file_name': 'Synthetic creation', 'content': 'New unique creation marker'}
        value = {'service': 'docs', 'tool': tool, 'arguments': arguments, 'operation_id': str(uuid.uuid4()),
                 'reason': 'Create the requested synthetic document.', 'verification_text': ['New unique creation marker']}
        value.update(extra)
        return value

    def edit(self, tool, arguments, after, markers=None):
        self.helper.after = after
        return self.zoom.write(self.args(tool, arguments=arguments, verification_text=markers or []))

    def test_discovery_schema_and_read_stays_read_only(self):
        catalog = self.zoom.catalog({'service': 'docs'})
        self.assertEqual(set(catalog['write_tools']), WRITE_TOOLS['docs'])
        for tool in WRITE_TOOLS['docs']:
            self.assertEqual(self.zoom.schema({'service': 'docs', 'tool': tool})['operation'], 'write')
            before = len(self.helper.calls)
            with self.assertRaises(ZoomError):
                self.zoom.read({'service': 'docs', 'tool': tool, 'arguments': {}})
            self.assertEqual(len(self.helper.calls), before)
        # The precise XML writer remains responsible for its original five
        # operations. Other exported Docs mutations now use the generic writer;
        # discovery must expose them without pretending the account granted them.
        for tool in ('docs_file_delete', 'docs_file_add_collaborators', 'docs_comment_create', 'docs_file_transfer_ownership', 'docs_file_modify_general_access_policy'):
            self.assertIn(tool, catalog['write_tools'])
            self.assertEqual(self.zoom.schema({'service': 'docs', 'tool': tool})['operation'], 'write')
        self.assertEqual(self.helper.writes, 0)
        self.assertIn('docs', self.zoom.status()['write_services'])
        self.assertEqual({service for service, tools in WRITE_TOOLS.items() if tools}, set(self.zoom.status()['write_services']))

    def test_create_and_durable_exact_retry_no_duplicate_or_credentials(self):
        args = self.args()
        result = self.zoom.write(args)
        self.assertTrue(result['committed'] and result['verified'])
        self.assertEqual(result['file_id'], 'created-doc')
        self.assertEqual(result['file_link'], 'https://docs.zoom.us/doc/synthetic')
        action, context = self.gate.calls[0]
        self.assertEqual(action['arguments'], args['arguments'])
        self.assertEqual(context['connection_id'], 'synthetic-connection')
        reopened = ZoomConnector(self.data, helper='/usr/bin/true', runner=self.helper, gate=self.gate)
        self.assertTrue(reopened.write(args)['replayed'])
        self.assertEqual(self.helper.writes, 1)
        self.assertEqual(len(self.gate.calls), 1)
        path = self.data / 'zoom-doc-operations.sqlite'
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertNotIn('New unique creation marker', path.read_bytes().decode('latin1'))
        args['arguments']['content'] = 'Different content'
        with self.assertRaisesRegex(ZoomError, 'different content'):
            reopened.write(args)
        self.assertEqual(self.helper.writes, 1)

    def test_all_edit_operations_and_normalized_inline_styles(self):
        result = self.edit('docs_file_update_block', {'file_id': 'target', 'block_id': 'first', 'block': '<text><b><i>Updated marker</i></b></text>'},
            {'content': '<page block_id="page"><text block_id="first"><i><b>Updated marker</b></i></text><text block_id="last">Existing unique marker</text></page>'}, ['Updated marker'])
        self.assertTrue(result['verified'])
        inserted = self.edit('docs_file_insert_blocks', {'file_id': 'target', 'blocks': '<text>Inserted marker</text>', 'positioning': {'below_block_id': 'last'}},
            {'content': self.helper.doc['content'].replace('</page>', '<text block_id="new">Inserted marker</text></page>')}, ['Inserted marker'])
        self.assertTrue(inserted['committed'] and inserted['content_observed'])
        self.assertFalse(inserted['verified'], 'Content alone does not establish insertion position')
        replaced = self.edit('docs_file_replace_range_of_blocks', {'file_id': 'target', 'start_block_id': 'new', 'end_block_id': 'new', 'blocks': '<text>Replacement marker</text>'},
            {'content': self.helper.doc['content'].replace('<text block_id="new">Inserted marker</text>', '<text block_id="replacement">Replacement marker</text>')}, ['Replacement marker'])
        self.assertTrue(replaced['committed'] and replaced['content_observed'])
        self.assertFalse(replaced['verified'], 'The model must inspect the precise replacement region')
        self.helper.after = None
        renamed = self.zoom.write(self.args('docs_file_modify_metadata', arguments={'id': 'target', 'file_name': 'Renamed document'}, verification_text=[]))
        self.assertTrue(renamed['verified'])
        self.assertEqual(self.helper.writes, 4)

    def test_denial_is_terminal_and_exact_gate_cannot_mutate_payload(self):
        args = self.args()
        self.gate.deny = True
        for _ in range(2):
            with self.assertRaises(ZoomError) as error:
                self.zoom.write(args)
            self.assertEqual(error.exception.state, 'denied')
        self.assertEqual(len(self.gate.calls), 1)
        self.assertEqual(self.helper.writes, 0)
        self.gate.deny = False
        self.gate.on_ask = lambda action, context: action['arguments'].update(content='Different unapproved content')
        with self.assertRaises(ZoomError) as error:
            self.zoom.write(self.args())
        self.assertEqual(error.exception.state, 'invalid_approval')
        self.assertEqual(self.helper.writes, 0)

    def test_connection_or_document_change_while_approving_blocks_write(self):
        self.gate.on_ask = lambda *_: self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'different-connection'}))
        with self.assertRaises(ZoomError) as error:
            self.zoom.write(self.args())
        self.assertEqual(error.exception.state, 'disconnected')
        self.assertEqual(self.helper.writes, 0)
        self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'synthetic-connection'}))
        self.gate.on_ask = lambda *_: self.helper.doc.update(content=BASE.replace('Original paragraph', 'Someone else edited'))
        args = self.args('docs_file_update_block', arguments={'file_id': 'target', 'block_id': 'first', 'block': '<text>New text</text>'}, verification_text=['New text'])
        with self.assertRaises(ZoomError) as error:
            self.zoom.write(args)
        self.assertEqual(error.exception.state, 'stale_document')
        self.assertEqual(self.helper.writes, 0)

    def test_new_chat_context_during_final_read_blocks_the_approved_commit(self):
        for automatic in (False, True):
            with self.subTest(automatic=automatic):
                events = []
                gate = ApprovalGate(lambda kind, **values: events.append(dict(type=kind, **values)), auto_approve=automatic)
                def reply(_timeout):
                    card = next(event for event in reversed(events) if event['type'] == 'approval')
                    return {'approval_id': card['approval_id'], 'action_hash': card['action_hash'], 'decision': 'approve'}
                gate.reader = reply
                self.zoom.gate = gate
                reads = 0
                def changed_context():
                    nonlocal reads
                    reads += 1
                    if reads == 2:
                        gate.invalidate_pending()
                self.helper.before_read = changed_context
                args = self.args('docs_file_update_block', arguments={'file_id': 'target', 'block_id': 'first', 'block': '<text>New content</text>'}, verification_text=['New content'])
                with self.assertRaises(ValueError):
                    self.zoom.write(args)
                self.assertGreaterEqual(reads, 2)
                self.assertEqual(self.helper.writes, 0,
                                 'The last content read must not allow a stale conversation approval to commit')
                self.assertEqual(sum(event['type'] == 'approval' for event in events), 0 if automatic else 1)

    def test_read_only_unknown_permission_unknown_fields_and_block_bounds(self):
        base = self.args('docs_file_update_block', arguments={'file_id': 'target', 'block_id': 'first', 'block': '<text>New text</text>'}, verification_text=['New text'])
        for permission in (False, None):
            self.helper.doc['can_edit'] = permission
            with self.assertRaises(ZoomError) as error:
                self.zoom.write(base)
            self.assertEqual(error.exception.state, 'permission_denied')
        self.helper.doc['can_edit'] = True
        cases = [
            ('docs_file_modify_metadata', {'id': 'target', 'file_name': 'X', 'owner_id': 'outsider'}),
            ('docs_file_insert_blocks', {'file_id': 'target', 'blocks': '<text>X</text>', 'positioning': {'wrong_key': 'last'}}),
            ('docs_file_update_block', {'file_id': 'target', 'block_id': 'first', 'block': '<text>X</text><text>Ignored</text>'}),
            ('docs_file_update_block', {'file_id': 'target', 'block_id': 'first', 'block': '<h1>Wrong type</h1>'}),
            ('docs_file_replace_range_of_blocks', {'file_id': 'target', 'start_block_id': 'last', 'end_block_id': 'first', 'blocks': '<text>X</text>'}),
            ('docs_file_replace_range_of_blocks', {'file_id': 'target', 'start_block_id': 'first', 'end_block_id': 'first', 'blocks': ' '})]
        for tool, arguments in cases:
            with self.assertRaises(ZoomError):
                self.zoom.write(self.args(tool, arguments=arguments, verification_text=[]))
        self.assertFalse(self.gate.calls)
        self.assertEqual(self.helper.writes, 0)

    def test_timeout_unknown_ack_and_permission_failure_never_replay(self):
        for failure, state in [(ZoomError('timeout', 'Synthetic timeout'), 'outcome_unknown'),
                               (ZoomError('permission_denied', 'Synthetic denied'), 'permission_denied')]:
            self.helper.fail = failure
            args = self.args()
            writes = self.helper.writes
            for _ in range(2):
                with self.assertRaises(ZoomError) as caught:
                    self.zoom.write(args)
                self.assertEqual(caught.exception.state, state)
            self.assertEqual(self.helper.writes, writes + 1)
        self.helper.fail = None
        self.helper.ack = {}
        args = self.args()
        for _ in range(2):
            with self.assertRaises(ZoomError) as caught:
                self.zoom.write(args)
            self.assertEqual(caught.exception.state, 'outcome_unknown')
        self.assertEqual(self.helper.writes, 3)

    def test_saved_but_unverified_is_not_repeated_and_old_marker_cannot_verify_noop(self):
        args = self.args('docs_file_insert_blocks', arguments={'file_id': 'target', 'blocks': '<text>Existing unique marker</text>'}, verification_text=['Existing unique marker'])
        result = self.zoom.write(args)  # helper acknowledges but deliberately leaves document unchanged
        self.assertTrue(result['committed'])
        self.assertFalse(result['verified'])
        self.assertTrue(self.zoom.write(args)['replayed'])
        self.assertEqual(self.helper.writes, 1)
        bad = self.args('docs_file_update_block', arguments={'file_id': 'target', 'block_id': 'first', 'block': '<text>Existing unique marker</text>'}, verification_text=['Existing unique marker'])
        result = self.zoom.write(bad)
        self.assertFalse(result['verified'], 'A marker in a different block must not verify this target')
        unrelated = self.args('docs_file_update_block', arguments={'file_id': 'target', 'block_id': 'first', 'block': '<text>Actually new text</text>'}, verification_text=['Existing unique marker'])
        with self.assertRaises(ZoomError):
            self.zoom.write(unrelated)
        self.assertEqual(self.helper.writes, 2)
        self.helper.fail_read_after_write = True
        created = self.zoom.write(self.args())
        self.assertTrue(created['committed'])
        self.assertFalse(created['verified'])

    def test_no_ack_edit_requires_real_target_change_not_old_marker(self):
        self.helper.ack = {}
        args = self.args('docs_file_update_block', arguments={'file_id': 'target', 'block_id': 'first', 'block': '<text>Existing unique marker</text>'}, verification_text=['Existing unique marker'])
        with self.assertRaises(ZoomError) as caught:
            self.zoom.write(args)
        self.assertEqual(caught.exception.state, 'outcome_unknown')
        self.helper.after = {'content': BASE.replace('Original paragraph', 'Actually updated text')}
        result = self.zoom.write(self.args('docs_file_update_block', arguments={'file_id': 'target', 'block_id': 'first', 'block': '<text>Actually updated text</text>'}, verification_text=['Actually updated text']))
        self.assertTrue(result['committed'] and result['verified'])

    def test_atomic_inline_content_and_wrong_position_are_not_verified(self):
        for submitted, observed in [('<text>A<br/>B</text>', '<text block_id="first">AB</text>'),
                                     ('<text>Due <mention-date date="2026-10-22"/></text>', '<text block_id="first">Due </text>')]:
            self.helper.after = {'content': '<page block_id="page">' + observed + '</page>'}
            result = self.zoom.write(self.args('docs_file_update_block', arguments={'file_id': 'target', 'block_id': 'first', 'block': submitted}, verification_text=[]))
            self.assertFalse(result['verified'])
            self.helper.doc['content'] = BASE
        self.helper.after = {'content': BASE.replace('</page>', '<text block_id="appended">Inserted at the wrong end</text></page>')}
        result = self.zoom.write(self.args('docs_file_insert_blocks', arguments={'file_id': 'target', 'blocks': '<text>Inserted at the wrong end</text>', 'positioning': {'above_block_id': 'first'}}, verification_text=['Inserted at the wrong end']))
        self.assertTrue(result['committed'])
        self.assertFalse(result['verified'])
        self.assertEqual(result['verification_scope'], 'position_and_structure_need_review')

    def test_tool_registration_uses_existing_gate_and_no_gate_no_write(self):
        registrations = {}
        def register(name, description, properties, required, handler):
            registrations[name] = handler
        register_zoom(register, lambda description: {'type': 'string', 'description': description}, self.data, gate=self.gate)
        self.assertIn('zoom_write', registrations)
        registrations.clear()
        register_zoom(register, lambda description: {'type': 'string', 'description': description}, self.data)
        self.assertNotIn('zoom_write', registrations)
        self.zoom.gate = None
        with self.assertRaises(ZoomError) as caught:
            self.zoom.write(self.args())
        self.assertEqual(caught.exception.state, 'approval_unavailable')


if __name__ == '__main__':
    unittest.main()
