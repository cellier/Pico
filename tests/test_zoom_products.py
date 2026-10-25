from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from zoom_connector import ZoomError
from zoom_operations import READ_TOOLS, WRITE_TOOLS
from zoom_products import ZoomProductGuide, register_zoom_products, _PRODUCTS
from register_zoom import register_zoom


class FakeZoom:
    def __init__(self):
        self.calls = []
        self.enabled = True
        self.failure = None
        self.omitted = set()

    def status(self):
        self.calls.append(('status',))
        return {'enabled': self.enabled, 'state': 'connected' if self.enabled else 'disconnected',
                'message': 'Current local state', 'verified_at': '2026-10-24T00:00:00Z',
                'verification': 'last_successful_request'}

    def catalog(self, args):
        self.calls.append(('catalog', args['service']))
        if self.failure:
            raise self.failure
        service = args['service']
        reads = sorted(READ_TOOLS[service] - self.omitted)
        writes = sorted(WRITE_TOOLS[service] - self.omitted)
        return {'tools': sorted(reads + writes), 'read_tools': reads, 'write_tools': writes}


class ZoomProductGuideTests(unittest.TestCase):
    def setUp(self):
        self.zoom = FakeZoom()
        self.guide = ZoomProductGuide(self.zoom)

    def test_index_is_local_only_and_contains_all_requested_products(self):
        result = self.guide.guide({})
        products = {item['id'] for item in result['products']}
        self.assertTrue({'calendar', 'chat', 'meeting', 'docs', 'sheets', 'slides', 'paper', 'clips', 'email'} <= products)
        self.assertEqual(self.zoom.calls, [('status',)])
        self.assertFalse(result['connection']['operation_permission_verified'])
        self.assertIn('No product action was executed', result['evidence'])

    def test_chinese_and_english_aliases_resolve_without_guessing_services(self):
        for alias, key in [('日历', 'calendar'), ('Zoom Team Chat', 'chat'), ('邮件', 'email'),
                           ('Zoom Slides', 'slides'), ('paper_doc', 'paper'), ('多维表格', 'data_tables')]:
            with self.subTest(alias=alias):
                result = self.guide.guide({'product': alias})
                self.assertEqual(result['product_id'], key)
        self.assertFalse(any(call[1] in ('slides', 'paper') for call in self.zoom.calls if call[0] == 'catalog'))

    def test_canvas_and_paper_are_distinct_native_products(self):
        for alias in ('Canvas', '画布', 'Zoom Canvas'):
            self.assertEqual(self.guide.guide({'product': alias})['product_id'], 'docs')
        paper = self.guide.guide({'product': 'Paper', 'intent': 'advanced'})
        self.assertIn('Paged rich-text document', paper['product']['product_kind'])
        advanced = paper['recommended_operation']['summary']
        for detail in ('margins', 'headers/footers', 'page numbers', 'fonts'):
            self.assertIn(detail, advanced)
        self.assertNotIn('canvas', advanced.casefold())

    def test_docs_import_export_use_real_worker_file_tools_not_unregistered_helper_extras(self):
        doc = self.guide.guide({'product': 'docs'})['product']['operations']
        self.assertEqual(doc['import']['pico_tools'], ['read_document'])
        self.assertIn('docs_file_create_with_content', doc['import']['currently_discovered_tools'])
        self.assertIn('truncated', doc['import']['summary'])
        self.assertEqual(doc['export']['pico_tools'], ['save_document'])
        self.assertIn('docs_file_get_content', doc['export']['currently_discovered_tools'])
        self.assertIn('child-page trees', doc['export']['summary'])
        self.assertNotIn('zoomdoc_', str(doc))
        self.assertNotIn('registered workspace-confined Docs', str(doc))

    def test_chat_file_helper_routes_name_actual_registered_pico_tools(self):
        registrations = []
        with tempfile.TemporaryDirectory() as directory:
            register_zoom(lambda *args: registrations.append(args),
                          lambda description: {'type': 'string', 'description': description},
                          Path(directory), gate=object(), workspace=Path(directory))
        registered = {args[0] for args in registrations}
        chat = self.guide.guide({'product': 'chat'})['product']['operations']
        for action, expected in [('import', 'zoom_upload_files'), ('share', 'zoom_upload_files'), ('export', 'zoom_download_files')]:
            self.assertEqual(chat[action]['local_helpers'], [expected])
            self.assertIn(expected, registered)
        self.assertNotIn('zoom_chat_send_file', str(chat))
        self.assertNotIn('zoom_chat_download_file', str(chat))

    def test_slides_paper_search_filters_are_metadata_only_and_writes_use_native_ui(self):
        for product, file_type in [('slides', 'presentation'), ('paper', 'paper_doc')]:
            with self.subTest(product=product):
                result = self.guide.guide({'product': product, 'intent': '新建'})
                self.assertEqual(result['file_discovery']['arguments_hint']['file_types'], [file_type])
                self.assertTrue(result['file_discovery']['metadata_only'])
                self.assertTrue(result['product']['native_product_required'])
                self.assertTrue(result['product']['prohibited_substitutes'])
                for action in ('create', 'edit', 'delete', 'share', 'import', 'export', 'advanced'):
                    self.assertEqual(result['product']['operations'][action]['route'], 'signed_in_native_or_browser_ui')
                    self.assertEqual(result['product']['operations'][action]['currently_discovered_tools'], [])
                self.assertNotIn('canvas_create_file', result['recommended_operation']['candidate_tools'])

    def test_current_catalog_is_evidence_and_missing_candidate_is_not_callable(self):
        self.zoom.omitted.add('sheets_create_spreadsheet')
        result = self.guide.guide({'product': 'sheets', 'intent': 'create'})
        operation = result['recommended_operation']
        self.assertIn('sheets_create_spreadsheet', operation['candidate_tools'])
        self.assertNotIn('sheets_create_spreadsheet', operation['currently_discovered_tools'])
        self.assertIn('sheets_add_worksheet', operation['currently_discovered_tools'])
        self.assertFalse(result['current_catalogs'][0]['operation_permission_verified'])

    def test_sheets_advanced_operations_and_mail_attachment_workflow_are_explicit(self):
        sheet = self.guide.guide({'product': '电子表格', 'intent': '高级'})
        actions = sheet['recommended_operation']['action_names']
        self.assertTrue({'addChart', 'createPivotTable', 'addConditionalFormattingRule', 'setFilter', 'sortRange'} <= set(actions))
        mail = self.guide.guide({'product': 'email', 'intent': 'create'})
        text = mail['recommended_operation']['summary']
        self.assertIn('Base64', text)
        self.assertIn('mcp_send_message has no attachment field', text)
        self.assertIn('zmail_send_draft', mail['recommended_operation']['currently_discovered_tools'])

    def test_clips_avatar_creation_is_not_ordinary_upload(self):
        create = self.guide.guide({'product': 'clips', 'intent': '新建'})['recommended_operation']
        self.assertIn('asynchronous', create['summary'])
        self.assertIn('clip_create', create['currently_discovered_tools'])
        upload = self.guide.guide({'product': 'clips', 'intent': '上传'})['recommended_operation']
        self.assertIn('not a local upload API', upload['summary'])
        self.assertEqual(upload['currently_discovered_tools'], [])

    def test_permission_error_is_retained_without_false_product_readonly_claim(self):
        self.zoom.failure = ZoomError('permission_denied', 'The requested API permission is not granted.')
        result = self.guide.guide({'product': 'email', 'intent': 'edit'})
        self.assertEqual(result['current_catalogs'][0]['discovery_state'], 'permission_denied')
        self.assertFalse(result['current_catalogs'][0]['operation_permission_verified'])
        self.assertIn('not evidence', result['current_catalogs'][0]['note'])
        boundaries = ' '.join(result['ui_route']['boundaries'])
        self.assertIn('administrator restriction', boundaries)
        self.assertIn('object’s actual access prohibition', boundaries)
        self.assertIn('tokens, cookies', boundaries)

    def test_disabled_status_preserved_and_no_silent_ui_bypass(self):
        self.zoom.enabled = False
        self.zoom.failure = ZoomError('disconnected', 'Pico Zoom access is not connected.')
        result = self.guide.guide({'product': 'docs'})
        self.assertFalse(result['connection']['enabled'])
        self.assertEqual(result['connection']['state'], 'disconnected')
        self.assertEqual(result['current_catalogs'][0]['discovery_state'], 'disconnected')
        self.assertIn('disabling Zoom access', ' '.join(result['ui_route']['boundaries']))

    def test_unknown_action_and_product_route_to_actual_ui_instead_of_impossible(self):
        result = self.guide.guide({'product': 'slides', 'intent': '添加转场动画'})
        self.assertIsNone(result['matched_intent'])
        self.assertIn('actual Zoom UI', result['recommended_operation']['summary'])
        self.assertEqual(result['recommended_operation']['route'], 'signed_in_native_or_browser_ui')
        unknown = self.guide.guide({'product': 'Zoom Future Product', 'intent': 'new custom object'})
        self.assertEqual(unknown['mode'], 'native_ui_lookup')
        self.assertIn('not an unsupported-action verdict', unknown['next_step'])

    def test_every_api_candidate_matches_the_audited_exact_service_catalog(self):
        for product in _PRODUCTS.values():
            audited = set().union(*(READ_TOOLS[service] | WRITE_TOOLS[service]
                                    for service in product['services']))
            self.assertEqual(set(product['operations']), {'read', 'create', 'edit', 'delete', 'share', 'import', 'export', 'advanced'})
            for action, operation in product['operations'].items():
                with self.subTest(product=product['name'], action=action):
                    self.assertFalse(set(operation['candidate_tools']) - audited)

    def test_guide_response_is_independent_and_rejects_malformed_arguments(self):
        first = self.guide.guide({'product': 'slides'})
        first['product']['operations']['read']['candidate_tools'].clear()
        second = self.guide.guide({'product': 'slides'})
        self.assertEqual(second['product']['operations']['read']['candidate_tools'], ['docs_file_search'])
        for invalid in (None, [], {'product': 3}, {'intent': []}, {'product': 'a' * 161}, {'extra': True}):
            with self.subTest(invalid=invalid), self.assertRaises(ZoomError):
                self.guide.guide(invalid)

    def test_registration_is_one_readonly_tool_with_optional_strings(self):
        registrations = []
        result = register_zoom_products(lambda *args: registrations.append(args),
                                        lambda description: {'type': 'string', 'description': description}, self.zoom)
        self.assertIsInstance(result, ZoomProductGuide)
        self.assertEqual(len(registrations), 1)
        name, description, schema, required, callback = registrations[0]
        self.assertEqual(name, 'zoom_product_guide')
        self.assertEqual(required, [])
        self.assertEqual(set(schema), {'product', 'intent'})
        self.assertIn('Does not change Zoom', description)
        self.assertEqual(callback({'product': 'Paper', 'intent': 'edit'})['product_id'], 'paper')


if __name__ == '__main__':
    unittest.main()
