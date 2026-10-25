"""Exercise Pico's real Chat/Task Zoom tool routing without account or model calls."""
import copy
import io
import json
import os
import sys
import tempfile
import types
import unittest
import uuid
from pathlib import Path
from unittest.mock import PropertyMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
import worker
from register_zoom import ZOOM_INSTRUCTIONS
from zoom_connector import ZoomError, WRITE_TOOLS
from mac_bridge import ApprovalGate


ZOOM_TOOLS = {'zoom_status', 'zoom_discover', 'zoom_schema', 'zoom_read', 'zoom_write',
              'zoom_product_guide', 'zoom_ui_commit'}


class ZoomWorkerTests(unittest.TestCase):
    def invoke(self, *, mode='chat', scenario='read', failure=None, automatic=False, write_case=None,
               product='slides', intent='create', ui_denied=False, ui_kind='ax_press'):
        """Use worker.main, its real registrations/wrapper, and a deterministic agent."""
        tools, definitions, observations, results = {}, {}, {}, []
        owner = self
        write_case = write_case or ('docs', 'docs_file_create_with_content',
                                    {'file_name': 'Synthetic worker fixture', 'content': '# Fixture\n\nSynthetic body.'})
        write_service, write_tool, write_arguments = write_case
        native_actions = []
        native_app = {'pid': 482017, 'name': 'Zoom Workplace', 'bundle_id': 'us.zoom.xos',
                      'path': '/Applications/zoom.us.app'}
        native_state = {'app': native_app,
                        'windows': [{'title': 'Zoom Slides — synthetic@example.invalid'}],
                        'nodes': [{'element_index': 7, 'role': 'AXButton', 'title': 'Create'}],
                        'text': 'Zoom Slides. Signed in as synthetic@example.invalid. Create.'}
        def perform_native(index, action):
            native_actions.append((index, action))
            return {'issued_to_private_fixture': True}
        def type_native(text, **options):
            native_actions.append(('type', text, options.get('app')))
            return {'typed_only_into_private_fixture': True}
        native = types.SimpleNamespace(list_apps=lambda: [copy.deepcopy(native_app)],
                                       get_app_state=lambda *_args, **_kwargs: copy.deepcopy(native_state),
                                       ax=types.SimpleNamespace(perform=perform_native), type=type_native)

        def approval_reply(_timeout):
            emitted = [json.loads(line) for line in output.getvalue().splitlines()]
            card = next(row for row in reversed(emitted) if row['type'] == 'approval')
            return {'approval_id': card['approval_id'], 'action_hash': card['action_hash'],
                    'decision': 'deny' if ui_denied else 'approve'}

        class Registry:
            def register(self, **values):
                tools[values['name']] = values['handler']
                definitions[values['name']] = values['schema']

        class Agent:
            def __init__(self, **options):
                observations['agent_options'] = options

            def run_conversation(self, prompt, **options):
                observations.update(options)
                if scenario == 'feed':
                    owner.assertTrue(ZOOM_TOOLS.isdisjoint(tools))
                    owner.assertNotIn(ZOOM_INSTRUCTIONS, options['system_message'])
                    owner.assertEqual(set(tools), worker.FEED_TOOLS)
                else:
                    owner.assertTrue(ZOOM_TOOLS.issubset(tools))
                    owner.assertIn(ZOOM_INSTRUCTIONS, options['system_message'])
                    owner.assertIn('zoom_schema', options['system_message'])
                    owner.assertIn('permission', options['system_message'].lower())
                    if scenario == 'write':
                        names = [('zoom_status', {}),
                                 ('zoom_discover', {'service': write_service}),
                                 ('zoom_schema', {'service': write_service, 'tool': write_tool}),
                                 ('zoom_write', {'service': write_service, 'tool': write_tool,
                                                 'arguments': write_arguments,
                                                 'operation_id': str(uuid.uuid4()),
                                                 'reason': 'Create the requested synthetic fixture.',
                                                 'verification_text': ['Synthetic body.']})]
                        observations['write_arguments'] = names[-1][1]
                    elif scenario == 'product':
                        names = [('zoom_product_guide', {'product': product, 'intent': intent})]
                    elif scenario == 'local_pptx':
                        names = [('presentation_guide', {})]
                    elif scenario == 'ui_commit':
                        worker.ACTIVE_CAP.gate.reader = approval_reply
                        names = [('mac_observe', {'app': 'us.zoom.xos', 'screenshot': False})]
                    else:
                        names = [('zoom_status', {}),
                                 ('zoom_discover', {'service': 'contact'}),
                                 ('zoom_schema', {'service': 'contact', 'tool': 'contacts_search'}),
                                 ('zoom_read', {'service': 'contact', 'tool': 'contacts_search',
                                                'arguments': {'keyword': 'fixture', 'limit': 1}})]
                    for name, args in names:
                        # Callback use is the real agent's expected event/archive flow.
                        callback = observations['agent_options']
                        callback['tool_start_callback'](name, name, args)
                        value = json.loads(tools[name](args))
                        callback['tool_complete_callback'](name, name, args, value)
                        results.append((name, value))
                        if scenario == 'ui_commit' and name == 'mac_observe':
                            ui_request = {'product': 'slides', 'operation': 'create',
                                          'target': {'account': 'synthetic@example.invalid', 'resource': 'private-workspace',
                                                     'url': 'https://docs.zoom.us/private-fixture-workspace'},
                                          'expected': {'title': 'Private native Slides fixture', 'slide_count': 2},
                                          'action': {'app': 'us.zoom.xos', 'observation_id': value['observation_id'],
                                                     'kind': 'ax_press', 'element_index': 7},
                                          'operation_id': str(uuid.uuid4()),
                                          'reason': 'Create only this exact native Slides fixture.'}
                            if ui_kind == 'type':
                                ui_request['operation'] = 'update'
                                ui_request['expected'] = {'body': 'Exact original autosaved body, with 中文 and a line break.\nSecond line.'}
                                ui_request['action'] = {'app': 'us.zoom.xos', 'observation_id': value['observation_id'],
                                                        'kind': 'type', 'text': ui_request['expected']['body']}
                                ui_request['reason'] = 'Apply only this exact autosaved body to the observed native deck.'
                            observations['ui_request'] = copy.deepcopy(ui_request)
                            names.append(('zoom_ui_commit', ui_request))
                needs_input = failure is not None or scenario == 'ui_commit'
                tools['report_outcome']({'status': 'needs_input' if needs_input else 'ready',
                                         'summary': ('The native save still needs independent readback.' if scenario == 'ui_commit' else
                                                     'Zoom API access is missing.' if failure is not None else 'Fixture routing/result is available.')})
                history = options['conversation_history']
                return {'completed': True,
                        'final_response': 'Connect Zoom in Pico Settings.' if needs_input else 'Fixture Zoom result.',
                        'messages': history + [{'role': 'user', 'content': prompt},
                                               {'role': 'assistant', 'content': 'Fixture result.'}],
                        'current_turn_user_idx': len(history)}

        class FakeFeedRefresh:
            def __init__(self, repository, feed_id):
                self.finished = False
            def collect(self):
                return {'candidates': []}
            def prompt_context(self, collected):
                return ''
            def finish(self, **options):
                self.finished = True
                return {'status': 'ok', 'published': 0, 'did_publish': False}

        registry_module, agent_module = types.ModuleType('tools.registry'), types.ModuleType('run_agent')
        registry_module.registry = Registry()
        agent_module.AIAgent = Agent
        old_cwd = Path.cwd()
        old_globals = {name: getattr(worker, name) for name in ('ACTIVE_CAP', 'ACTIVE_PHONE', 'ACTIVE_TURN', 'ACTIVE_CHAT', 'ACTIVE_CONTINUOUS') if hasattr(worker, name)}
        with tempfile.TemporaryDirectory() as temp:
            data = Path(temp)
            (data / 'config.json').write_text(json.dumps({'api_key': 'fixture-only',
                                                         'base_url': 'http://127.0.0.1:1', 'model': 'fixture'}))
            request = {'task_id': str(uuid.uuid4()), 'prompt': 'Read the relevant Zoom information.',
                       'run_id': str(uuid.uuid4()), 'message_id': str(uuid.uuid4()),
                       'new': False, 'auto_approve': automatic}
            if scenario == 'product':
                request['prompt'] = 'Explain how to ' + intent + ' the actual native Zoom ' + product + ' file in my account.'
            elif scenario == 'local_pptx':
                request['prompt'] = 'Give the workflow for making a local editable PowerPoint .pptx file.'
            elif scenario == 'ui_commit':
                request['prompt'] = 'Create the exact requested native Zoom Slides file in my signed-in account.'
            if mode == 'chat':
                request['mode'] = 'chat'
            if scenario == 'feed':
                request['feed_id'] = str(uuid.uuid4())
            output = io.StringIO()
            original_ask = ApprovalGate.ask
            try:
                with patch.dict(sys.modules, {'run_agent': agent_module, 'tools.registry': registry_module}), \
                     patch.dict(os.environ, {'TELOS_DATA_DIR': str(data)}), \
                     patch('sys.stdin', io.StringIO(json.dumps(request))), \
                     patch.object(worker, 'OUT', output), patch('openai.OpenAI') as client, \
                     patch('phone_bridge.prepare_phone_home', return_value=False), \
                     patch('phone_bridge.PhoneBridge.attach', return_value=False), \
                     patch('mac_bridge.MacBridge.mac', new_callable=PropertyMock, return_value=native), \
                     patch('feed_refresh.FeedRefresh', FakeFeedRefresh), \
                     patch('mac_bridge.ApprovalGate.ask', autospec=True) as approval, \
                     patch('zoom_connector.ZoomConnector', autospec=True) as connector:
                    approval.side_effect = original_ask if scenario in ('write', 'ui_commit') else AssertionError('Zoom reads must not ask for approval')
                    adapter = connector.return_value
                    adapter.status.return_value = {'enabled': failure is None,
                                                   'state': 'connected' if failure is None else 'disconnected',
                                                   'message': 'Fixture connection state', 'read_only': True}
                    adapter.catalog.return_value = {'service': 'contact', 'tools': ['contacts_search'], 'read_only': True}
                    adapter.schema.return_value = {'service': 'contact', 'tool': 'contacts_search',
                                                   'inputSchema': {'type': 'object', 'required': ['keyword']}}
                    adapter.read.return_value = {'result': {'contacts': [{'name': 'Fixture contact'}]},
                                                 'truncated': False, 'untrusted': True}
                    if scenario == 'write':
                        adapter.catalog.return_value = {'service': write_service, 'tools': [write_tool],
                                                        'read_only': False}
                        adapter.schema.return_value = {'service': write_service, 'tool': write_tool,
                                                       'operation': 'write', 'inputSchema': {'type': 'object', 'required': list(write_arguments)}}
                        def write_fixture(arguments):
                            # The adapter itself is mocked, but it exercises the
                            # exact gate injected by this real worker, including
                            # automatic execution versus native-card approval.
                            gate = connector.call_args.kwargs['gate']
                            def approved_reply(_timeout):
                                emitted = [json.loads(line) for line in output.getvalue().splitlines()]
                                card = next(row for row in reversed(emitted) if row['type'] == 'approval')
                                return {'approval_id': card['approval_id'], 'action_hash': card['action_hash'],
                                        'decision': 'approve'}
                            gate.reader = approved_reply
                            exact = gate.ask({'app': 'Zoom ' + write_service, 'kind': 'zoom_write',
                                              'reason': arguments['reason'], 'arguments': arguments}, {})
                            owner.assertEqual(exact['arguments'], arguments)
                            return {'committed': True, 'verified': True,
                                    'file_id': 'synthetic-file', 'file_link': 'https://example.test/synthetic-file'}
                        adapter.write.side_effect = write_fixture
                    elif scenario == 'product':
                        adapter.catalog.return_value = {'service': 'docs', 'tools': ['docs_file_search', 'canvas_create_file'],
                                                        'read_tools': ['docs_file_search'], 'write_tools': ['canvas_create_file'],
                                                        'read_only': False}
                        if failure is not None:
                            adapter.catalog.side_effect = failure
                    if failure is not None:
                        adapter.read.side_effect = failure
                    worker.main()
                    connector.assert_called_once()
                    self.assertEqual(connector.call_args.args, (data,))
                    gate = connector.call_args.kwargs['gate']
                    self.assertIs(gate, worker.ACTIVE_CAP.gate)
                    self.assertIsInstance(gate, ApprovalGate)
                    self.assertEqual(gate.auto_approve, automatic and scenario != 'feed')
                    client.return_value.chat.completions.create.assert_not_called()
                    if scenario in ('write', 'ui_commit'):
                        approval.assert_called_once()
                        self.assertIs(approval.call_args.args[0], gate)
                    else:
                        approval.assert_not_called()
                    if scenario == 'feed':
                        for name in ('status', 'catalog', 'schema', 'read', 'write'):
                            getattr(adapter, name).assert_not_called()
                        self.assertFalse(any(name.startswith('zoom_') for name in tools))
                    elif scenario == 'write':
                        self.assertEqual([call[0] for call in adapter.method_calls], ['status', 'catalog', 'schema', 'write'])
                        adapter.catalog.assert_called_once_with({'service': write_service})
                        adapter.schema.assert_called_once_with({'service': write_service, 'tool': write_tool})
                        adapter.write.assert_called_once_with(observations['write_arguments'])
                        adapter.read.assert_not_called()
                    elif scenario == 'product':
                        self.assertEqual([call[0] for call in adapter.method_calls], ['status', 'catalog'])
                        adapter.catalog.assert_called_once_with({'service': 'docs'})
                        adapter.read.assert_not_called()
                        adapter.write.assert_not_called()
                    elif scenario in ('local_pptx', 'ui_commit'):
                        self.assertFalse(adapter.method_calls, 'Local presentation guidance and native UI use no guessed Zoom API')
                    else:
                        # Registration binds the adapter's methods and preserves query arguments.
                        self.assertEqual([call[0] for call in adapter.method_calls], ['status', 'catalog', 'schema', 'read'])
                        adapter.catalog.assert_called_once_with({'service': 'contact'})
                        adapter.schema.assert_called_once_with({'service': 'contact', 'tool': 'contacts_search'})
                        adapter.read.assert_called_once_with({'service': 'contact', 'tool': 'contacts_search',
                                                              'arguments': {'keyword': 'fixture', 'limit': 1}})
                        adapter.write.assert_not_called()
                    events = [json.loads(line) for line in output.getvalue().splitlines()]
                    if scenario in ('write', 'ui_commit'):
                        self.assertEqual(sum(row['type'] == 'approval' for row in events), 0 if automatic else 1)
                        self.assertEqual(sum(row['type'] == 'auto_approved' for row in events), 1 if automatic else 0)
                    else:
                        self.assertFalse(any(event['type'].startswith('approval') for event in events))
                    self.assertEqual(events[-1]['type'], 'done')
                    self.assertEqual(events[-1]['status'], 'needs_input' if failure is not None or scenario == 'ui_commit' else 'ready')
                    observations['native_actions'] = list(native_actions)
                    return definitions, observations, results, events
            finally:
                os.chdir(old_cwd)
                for name, value in old_globals.items():
                    setattr(worker, name, value)

    def test_chat_and_task_expose_read_tools_with_exact_schema_and_no_approval(self):
        for mode in ('chat', 'task'):
            with self.subTest(mode=mode):
                definitions, observations, results, events = self.invoke(mode=mode)
                self.assertEqual(definitions['zoom_schema']['parameters']['required'], ['service', 'tool'])
                self.assertEqual(definitions['zoom_read']['parameters']['required'], ['service', 'tool', 'arguments'])
                self.assertEqual(definitions['zoom_read']['parameters']['properties']['arguments']['type'], 'object')
                self.assertTrue(all('error' not in value for _, value in results))
                self.assertEqual(results[-1][1]['result']['contacts'][0]['name'], 'Fixture contact')
                self.assertEqual([event['name'] for event in events if event['type'] == 'tool'][:4],
                                 ['zoom_status', 'zoom_discover', 'zoom_schema', 'zoom_read'])

    def test_disconnected_and_permission_failures_are_tool_errors_not_empty_results(self):
        for mode in ('chat', 'task'):
            for state, message in (
                    ('disconnected', 'Zoom is not connected. Connect Zoom in Pico Settings.'),
                    ('permission_denied', 'Your Zoom account has not granted access to this information.')):
                with self.subTest(mode=mode, state=state):
                    _, _, results, events = self.invoke(mode=mode, failure=ZoomError(state, message))
                    self.assertFalse(results[0][1]['enabled'])
                    self.assertEqual(results[-1], ('zoom_read', {'error': message}))
                    self.assertNotIn('result', results[-1][1])
                    self.assertNotIn('contacts', results[-1][1])
                    self.assertEqual(events[-1]['status'], 'needs_input')

    def test_background_feed_cannot_discover_or_call_zoom(self):
        for automatic in (False, True):
            with self.subTest(automatic=automatic):
                self.invoke(mode='task', scenario='feed', automatic=automatic)

    def test_chat_and_task_route_docs_writes_through_the_existing_execution_gate(self):
        for mode in ('chat', 'task'):
            for automatic in (False, True):
                with self.subTest(mode=mode, automatic=automatic):
                    definitions, observations, results, events = self.invoke(mode=mode, scenario='write', automatic=automatic)
                    properties = definitions['zoom_write']['parameters']['properties']
                    self.assertEqual(properties['service']['type'], 'string')
                    if 'enum' in properties['service']:
                        self.assertTrue({service for service, tools in WRITE_TOOLS.items() if tools}.issubset(properties['service']['enum']))
                    self.assertEqual(properties['arguments']['type'], 'object')
                    self.assertEqual(definitions['zoom_write']['parameters']['required'],
                                     ['service', 'tool', 'arguments', 'operation_id', 'reason'])
                    self.assertTrue(results[-1][1]['committed'])
                    self.assertTrue(results[-1][1]['verified'])
                    self.assertEqual([event['name'] for event in events if event['type'] == 'tool'][:4],
                                     ['zoom_status', 'zoom_discover', 'zoom_schema', 'zoom_write'])

    def test_multiple_zoom_services_use_the_same_chat_task_gate_and_preserve_exact_arguments(self):
        cases = [
            ('tasks', 'tasks_create', {'title': 'Isolated task', 'skip_notifications': True}),
            ('meeting', 'meeting_create', {'topic': 'Isolated meeting', 'duration': 20, 'start_time_local': '2026-10-25T10:00:00'}),
            ('calendar', 'calendar_insert_event', {'cal_id': 'isolated-calendar', 'summary': 'Isolated event',
                                                    'start': {'dateTime': '2026-10-25T10:00:00+08:00'},
                                                    'end': {'dateTime': '2026-10-25T10:20:00+08:00'}}),
            ('team_chat', 'team_chat_msg_send', {'chat_session_id': 'isolated-recipient', 'message_content': 'Private fixture only.'}),
            ('sheets', 'sheets_edit_cells', {'sheetId': 'isolated-sheet', 'worksheetId': 'isolated-tab',
                                            'cellValues': [{'range': 'A1', 'values': [['fixture']]}]}),
            ('mail', 'mcp_send_message', {'to': ['nobody@example.invalid'], 'subject': 'Fixture', 'text_body': 'No real send.'}),
        ]
        for case in cases:
            for mode in ('chat', 'task'):
                for automatic in (False, True):
                    with self.subTest(service=case[0], mode=mode, automatic=automatic):
                        definitions, observations, results, events = self.invoke(mode=mode, scenario='write', automatic=automatic, write_case=case)
                        self.assertEqual(observations['write_arguments']['arguments'], case[2])
                        service_schema = definitions['zoom_write']['parameters']['properties']['service']
                        if 'enum' in service_schema:
                            self.assertIn(case[0], service_schema['enum'])
                        self.assertTrue(results[-1][1]['committed'] and results[-1][1]['verified'])
                        self.assertEqual(events[-1]['status'], 'ready')

    def test_native_slides_and_paper_requests_get_real_product_routes_without_local_substitution(self):
        for mode, product, intent in (('chat', 'slides', 'create'), ('task', 'slides', 'edit'),
                                      ('chat', 'paper', 'edit'), ('task', 'paper', 'create')):
            with self.subTest(mode=mode, product=product, intent=intent):
                definitions, observations, results, events = self.invoke(mode=mode, scenario='product', product=product, intent=intent)
                self.assertEqual(definitions['zoom_product_guide']['parameters']['required'], [])
                guide = results[-1][1]
                self.assertEqual(guide['product_id'], product)
                self.assertTrue(guide['product']['native_product_required'])
                self.assertEqual(guide['recommended_operation']['route'], 'signed_in_native_or_browser_ui')
                self.assertTrue(guide['product']['prohibited_substitutes'])
                self.assertTrue(guide['file_discovery']['metadata_only'])
                self.assertEqual(guide['file_discovery']['arguments_hint']['file_types'], ['presentation' if product == 'slides' else 'paper_doc'])
                self.assertFalse(guide['connection']['operation_permission_verified'])
                self.assertFalse(observations['native_actions'])
                system = observations['system_message']
                self.assertIn('zoom_product_guide', system)
                self.assertIn('zoom_ui_commit', system)
                self.assertIn('Zoom Slides', system)
                self.assertIn('Paper', system)
                self.assertNotIn('For every PPT, PPTX, slides or deck creation request, call presentation_guide first', system,
                                 'The unconditional local-PPTX rule conflicts with a requested native Zoom Slides result')
                boundaries = ' '.join(guide['ui_route']['boundaries']).lower()
                for term in ('login', 'administrator', 'object', 'tokens', 'cookies', 'disabl', 'cancel'):
                    self.assertIn(term, boundaries)
                self.assertTrue('cdp' in system.lower() or 'remote debugging' in system.lower(),
                                'Existing UI access must not silently become a newly authorized browser/CDP connection')

    def test_a_catalog_permission_failure_is_preserved_without_declaring_the_native_product_impossible(self):
        _, observations, results, _ = self.invoke(scenario='product', product='slides', intent='create',
            failure=ZoomError('permission_denied', 'Fixture API scope is unavailable; actual item permissions are not established.'))
        guide = results[-1][1]
        self.assertEqual(guide['current_catalogs'][0]['discovery_state'], 'permission_denied')
        self.assertEqual(guide['recommended_operation']['route'], 'signed_in_native_or_browser_ui')
        self.assertFalse(guide['current_catalogs'][0]['operation_permission_verified'])
        self.assertIn('not evidence', guide['current_catalogs'][0]['note'].lower())
        self.assertFalse(observations['native_actions'])

    def test_local_powerpoint_retains_its_real_guide_and_reviewed_artifact_workflow(self):
        for mode in ('chat', 'task'):
            with self.subTest(mode=mode):
                definitions, observations, results, _ = self.invoke(mode=mode, scenario='local_pptx')
                self.assertEqual(results[0][0], 'presentation_guide')
                guide = results[0][1]
                self.assertIn('workflow', guide)
                self.assertIn('brief', guide['schema'])
                self.assertIn('expected_slide_count', guide['schema'])
                self.assertIn('slides', guide['schema'])
                system = observations['system_message']
                for name in ('presentation_guide', 'presentation_styles', 'create_presentation', 'review_presentation', 'finalize_presentation'):
                    self.assertIn(name, definitions)
                    self.assertIn(name, system)
                self.assertIn('local', system.lower())
                self.assertIn('render', system.lower())
                self.assertFalse(observations['native_actions'])

    def test_native_zoom_ui_commit_uses_the_same_real_manual_auto_or_denied_gate_without_claiming_a_cloud_save(self):
        for mode, automatic, denied in (('chat', False, False), ('task', True, False), ('chat', False, True)):
            with self.subTest(mode=mode, automatic=automatic, denied=denied):
                definitions, observations, results, events = self.invoke(mode=mode, scenario='ui_commit', automatic=automatic, ui_denied=denied)
                properties = definitions['zoom_ui_commit']['parameters']['properties']
                self.assertEqual(set(properties['action']['properties']['kind']['enum']), {'click', 'ax_press', 'key', 'type', 'ax_set'})
                self.assertNotIn('source', properties['action']['properties'])
                self.assertEqual(properties['action']['properties']['text']['maxLength'], 160000)
                result = results[-1][1]
                self.assertFalse(result['verified'])
                self.assertEqual(result['submitted'], not denied)
                self.assertEqual(observations['native_actions'], [] if denied else [(7, 'AXPress')])
                self.assertNotIn('cloud_url', result)
                self.assertEqual(events[-1]['status'], 'needs_input', 'A final native click is not proof the requested cloud file was saved')
                request = observations['ui_request']
                if not automatic:
                    card = next(row for row in events if row['type'] == 'approval')
                    action = json.loads(card['details'])
                    self.assertEqual(action['zoom_ui']['product'], 'slides')
                    self.assertEqual(action['zoom_ui']['target'], request['target'])
                    self.assertEqual(action['zoom_ui']['expected'], request['expected'])
                    self.assertEqual(action['zoom_ui']['operation_id'], request['operation_id'])
                if not denied:
                    self.assertEqual(result['state'], 'ui_submitted')
                    self.assertIn('not confirmation', result['notice'])

    def test_autosaved_native_text_uses_the_same_ui_commit_boundary_with_its_exact_original_text(self):
        _, observations, results, events = self.invoke(scenario='ui_commit', ui_kind='type')
        request = observations['ui_request']
        self.assertEqual(request['operation'], 'update')
        self.assertEqual(request['action']['text'], request['expected']['body'])
        self.assertEqual(observations['native_actions'], [('type', request['expected']['body'], '482017')])
        card = next(row for row in events if row['type'] == 'approval')
        action = json.loads(card['details'])
        self.assertEqual(action['text'], request['expected']['body'])
        self.assertEqual(action['zoom_ui']['expected'], request['expected'])
        self.assertTrue(results[-1][1]['submitted'])
        self.assertFalse(results[-1][1]['verified'])
        self.assertEqual(events[-1]['status'], 'needs_input')


if __name__ == '__main__':
    unittest.main()
