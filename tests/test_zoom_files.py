"""Local Zoom file transfers through a private fake helper, never a real account."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from zoom_connector import ZoomConnector, ZoomError
from zoom_files import LocalZoomFiles
from zoom_writes import ZoomGenericWriter


# Exact property/type/required contracts captured from local DevHelper metadata.
# Unlike gateway tools these are queried using `helper tool schema TOOL`.
SCHEMAS = {
    'zoom_chat_send_file': {'type': 'object', 'properties': {
        'chat_session_id': {'type': 'string'}, 'contact_email': {'type': 'string'},
        'file_paths': {'type': 'array', 'items': {'type': 'string'}}}, 'required': ['file_paths']},
    'zoom_chat_download_file': {'type': 'object', 'properties': {
        'file_ids': {'type': 'array', 'items': {'type': 'string'}},
        'save_dir': {'type': 'string'}}, 'required': ['file_ids']},
}


class Gate:
    def __init__(self):
        self.generation = 0
        self.calls = []
        self.on_ask = None
        self.deny = False

    def check_execution(self, generation=None):
        if generation is not None and generation != self.generation:
            raise ValueError('A new user message superseded this transfer.')

    def invalidate_pending(self):
        self.generation += 1

    def ask(self, action, context):
        self.calls.append((copy.deepcopy(action), copy.deepcopy(context)))
        if self.on_ask:
            self.on_ask(action, context)
        return None if self.deny else copy.deepcopy(action)


class Helper:
    def __init__(self):
        self.calls, self.uploads, self.downloads = [], [], []
        self.schemas = copy.deepcopy(SCHEMAS)
        self.upload_error = None
        self.upload_result = {'success': True, 'message_id': 'synthetic-upload-message'}
        self.download_result = None
        self.download_count = None
        self.on_download = None
        self.make_symlink = None

    def __call__(self, argv):
        self.calls.append(copy.deepcopy(argv))
        if argv[1:3] == ['tool', 'schema']:
            return json.dumps(self.schemas[argv[3]])
        if argv[1:3] != ['tool', 'run'] or argv[4] != '--args-json' or argv[-1] != '--json':
            raise AssertionError('Unexpected helper command: ' + repr(argv))
        tool, arguments = argv[3], json.loads(argv[5])
        if tool == 'zoom_chat_send_file':
            staged = [Path(path) for path in arguments['file_paths']]
            self.uploads.append({'arguments': copy.deepcopy(arguments),
                                 'bytes': [path.read_bytes() for path in staged],
                                 'modes': [path.stat().st_mode & 0o777 for path in staged],
                                 'parent_modes': [path.parent.stat().st_mode & 0o777 for path in staged]})
            if self.upload_error:
                raise self.upload_error
            return json.dumps(self.upload_result)
        if tool != 'zoom_chat_download_file':
            raise AssertionError('Unexpected local tool: ' + tool)
        destination = Path(arguments['save_dir'])
        self.downloads.append({'arguments': copy.deepcopy(arguments),
                               'initial_files': list(destination.iterdir()),
                               'mode': destination.stat().st_mode & 0o777})
        count = len(arguments['file_ids']) if self.download_count is None else self.download_count
        for index, file_id in enumerate(arguments['file_ids'][:count]):
            (destination / ('fixture-' + str(index) + '.bin')).write_bytes(('Attachment:' + file_id).encode())
        if self.make_symlink:
            (destination / 'unexpected-link.bin').symlink_to(self.make_symlink)
        if self.on_download:
            self.on_download(destination)
        result = {'success': True, 'save_dir': '/untrusted/server/path',
                  'files': [{'file_id': file_id, 'path': str(destination / ('fixture-' + str(index) + '.bin'))}
                            for index, file_id in enumerate(arguments['file_ids'][:count])]}
        if callable(self.download_result):
            result = self.download_result(result, destination)
        elif self.download_result is not None:
            result = self.download_result
        return json.dumps(result)


class ZoomFileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.data, self.workspace = self.root / 'data', self.root / 'conversation'
        self.data.mkdir()
        self.workspace.mkdir()
        self.settings = self.data / 'zoom-connection.json'
        self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'private-connection'}))
        self.first = self.workspace / 'Requested.pdf'
        self.second = self.workspace / 'Requested image.png'
        self.first.write_bytes(b'%PDF-private-fixture\x00\x01')
        self.second.write_bytes(b'\x89PNG-private-fixture')
        self.outside = self.root / 'unrelated-private-file.txt'
        self.outside.write_bytes(b'Must never upload or overwrite this external file.')
        self.helper, self.gate = Helper(), Gate()
        self.artifacts = []
        self.files = self.reopen()

    def tearDown(self):
        self.temp.cleanup()

    def reopen(self):
        zoom = ZoomConnector(self.data, helper='/usr/bin/true', runner=self.helper,
                             gate=self.gate, workspace=self.workspace)
        return LocalZoomFiles(zoom, artifact=self.artifacts.append)

    def upload(self, **updates):
        value = {'chat_session_id': 'resolved-synthetic-session',
                 'file_paths': [str(self.first), 'Requested image.png'],
                 'operation_id': str(uuid.uuid4()), 'reason': 'Send only these requested private fixtures.'}
        value.update(updates)
        return value

    def download(self, **updates):
        value = {'file_ids': ['observed-file-one', 'observed-file-two'],
                 'reason': 'Download only the two attachments the user requested.'}
        value.update(updates)
        return value

    def test_upload_sends_the_reviewed_bytes_from_private_staging_to_the_exact_target(self):
        request = self.upload()
        result = self.files.upload(request)
        self.assertTrue(result['committed'])
        self.assertFalse(result['verified'], 'An upload acknowledgement is not independent attachment readback')
        self.assertFalse(result['complete'])
        self.assertEqual(result['verification_scope'], 'provider_acknowledgement_only')
        self.assertEqual(result['requested_files'], [{'name': self.first.name, 'bytes': self.first.stat().st_size},
                                                     {'name': self.second.name, 'bytes': self.second.stat().st_size}])
        self.assertNotIn('files', result, 'Requested files must not be presented as an independently checked complete batch')
        self.assertEqual(result['target'], {'chat_session_id': request['chat_session_id']})
        self.assertEqual(result['message_ids'], ['synthetic-upload-message'])
        action, context = self.gate.calls[0]
        self.assertEqual(action['kind'], 'zoom_file_upload')
        self.assertEqual(action['tool'], 'zoom_chat_send_file')
        self.assertEqual(context['connection_id'], 'private-connection')
        self.assertEqual(action['arguments'], {'chat_session_id': request['chat_session_id'],
                                             'file_paths': [str(self.first), str(self.second)]})
        self.assertEqual(action['operation_id'], request['operation_id'])
        self.assertEqual(action['reason'], request['reason'])
        self.assertEqual([row['sha256'] for row in action['files']],
                         [hashlib.sha256(path.read_bytes()).hexdigest() for path in (self.first, self.second)])
        sent = self.helper.uploads[0]
        self.assertEqual(sent['bytes'], [self.first.read_bytes(), self.second.read_bytes()])
        self.assertEqual(sent['modes'], [0o400, 0o400])
        self.assertEqual(sent['parent_modes'], [0o700, 0o700])
        self.assertEqual(sent['arguments']['chat_session_id'], request['chat_session_id'])
        for path in map(Path, sent['arguments']['file_paths']):
            self.assertTrue(path.is_relative_to(self.workspace / '.pico-transfers'))
            self.assertNotIn(path, (self.first, self.second))
            self.assertFalse(path.exists(), 'Temporary staged copies are removed after the result is recorded')
        self.assertFalse(self.artifacts, 'Uploading an existing file must not republish it as a new result')

    def test_upload_replay_is_durable_and_operation_cannot_change_files_target_or_account(self):
        request = self.upload()
        self.files.upload(request)
        self.assertTrue(self.reopen().upload(copy.deepcopy(request))['replayed'])
        self.assertEqual(len(self.helper.uploads), 1)
        self.assertEqual(len(self.gate.calls), 1)
        changed_target = copy.deepcopy(request)
        changed_target['chat_session_id'] = 'another-session'
        changed_files = copy.deepcopy(request)
        changed_files['file_paths'] = [str(self.first)]
        for changed in (changed_target, changed_files):
            with self.assertRaises(ZoomError) as caught:
                self.reopen().upload(changed)
            self.assertEqual(caught.exception.state, 'operation_conflict')
        self.first.write_bytes(b'Changed source content')
        with self.assertRaises(ZoomError) as caught:
            self.reopen().upload(request)
        self.assertEqual(caught.exception.state, 'operation_conflict')
        self.first.write_bytes(b'%PDF-private-fixture\x00\x01')
        self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'another-account'}))
        with self.assertRaises(ZoomError) as caught:
            self.reopen().upload(request)
        self.assertEqual(caught.exception.state, 'operation_conflict')
        self.assertEqual(len(self.helper.uploads), 1)
        journal = self.data / 'zoom-doc-operations.sqlite'
        self.assertEqual(journal.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(b'%PDF-private-fixture', journal.read_bytes())

    def test_upload_unknown_timeout_or_partial_result_is_not_resent_with_same_or_new_id(self):
        for mode in ('timeout', 'partial', 'empty', 'failure_status'):
            with self.subTest(mode=mode):
                self.first.write_bytes(('Unique batch for ' + mode).encode())
                self.helper.upload_error = ZoomError('timeout', 'Fixture lost the response') if mode == 'timeout' else None
                self.helper.upload_result = ({'success': True, 'files': [{'success': True, 'message_id': 'one'},
                                                                        {'success': False, 'error': 'Other upload failed'}]}
                                             if mode == 'partial' else {})
                if mode == 'failure_status':
                    self.helper.upload_result = {'success': True, 'status': 'failure'}
                request = self.upload()
                before = len(self.helper.uploads), len(self.gate.calls)
                for changed_id in (False, False, True):
                    if changed_id:
                        request['operation_id'] = str(uuid.uuid4())
                    with self.assertRaises(ZoomError) as caught:
                        self.reopen().upload(request)
                    self.assertEqual(caught.exception.state, 'outcome_unknown')
                self.assertEqual((len(self.helper.uploads), len(self.gate.calls)), (before[0] + 1, before[1] + 1))

    def test_upload_source_staging_target_or_conversation_changes_during_review_do_not_send(self):
        for changed in ('source', 'staged', 'target', 'files_metadata', 'generation', 'connection'):
            with self.subTest(changed=changed):
                self.first.write_bytes(b'Original fixture for review')
                self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'private-connection'}))
                def on_ask(action, _context):
                    if changed == 'source': self.first.write_bytes(b'Changed after review')
                    elif changed == 'staged':
                        staged = next((self.workspace / '.pico-transfers').rglob('Requested.pdf'))
                        staged.chmod(0o600)
                        staged.write_bytes(b'Changed staged copy')
                    elif changed == 'target': action['arguments']['chat_session_id'] = 'unapproved-session'
                    elif changed == 'files_metadata': action['files'][0]['sha256'] = 'not-the-reviewed-file'
                    elif changed == 'generation': self.gate.invalidate_pending()
                    else: self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'changed-connection'}))
                self.gate.on_ask = on_ask
                with self.assertRaises((ZoomError, ValueError)):
                    self.reopen().upload(self.upload())
                self.assertFalse(self.helper.uploads)

    def test_upload_context_change_while_claiming_operation_is_rechecked_before_send(self):
        original_claim = ZoomGenericWriter._claim
        request = self.upload()
        def claim_then_new_message(journal, operation, digest, connection):
            value = original_claim(journal, operation, digest, connection)
            self.gate.invalidate_pending()
            return value
        with patch('zoom_files.ZoomGenericWriter._claim', side_effect=claim_then_new_message):
            with self.assertRaises((ValueError, ZoomError)):
                self.files.upload(request)
        self.assertFalse(self.helper.uploads, 'Waiting for the journal lock must not allow superseded authorization to send')
        with self.assertRaises(ZoomError) as caught:
            self.reopen().upload(request)
        self.assertEqual(caught.exception.state, 'superseded')
        self.assertEqual(len(self.gate.calls), 1)
        self.assertFalse(self.helper.uploads)

    def test_upload_denial_is_terminal_and_no_gate_does_not_send(self):
        request = self.upload()
        self.gate.deny = True
        for _ in range(2):
            with self.assertRaises(ZoomError) as caught:
                self.reopen().upload(request)
            self.assertEqual(caught.exception.state, 'denied')
        self.assertEqual(len(self.gate.calls), 1)
        self.files.zoom.gate = None
        with self.assertRaises(ZoomError) as caught:
            self.files.upload(self.upload())
        self.assertEqual(caught.exception.state, 'approval_unavailable')
        self.assertFalse(self.helper.uploads)

    def test_outside_workspace_symlinks_and_invalid_targets_never_upload(self):
        escape = self.workspace / 'escape.txt'
        escape.symlink_to(self.outside)
        for paths in ([str(self.outside)], ['../unrelated-private-file.txt'], [str(escape)],
                      [str(self.first), str(self.first)]):
            with self.subTest(paths=paths):
                with self.assertRaises(ZoomError):
                    self.files.upload(self.upload(file_paths=paths))
        for updates in ({'chat_session_id': ''}, {'contact_email': 'nobody@example.invalid'},
                        {'chat_session_id': 'session\nInjected'}, {'save_dir': str(self.root)}):
            with self.subTest(updates=updates):
                with self.assertRaises(ZoomError):
                    self.files.upload(self.upload(**updates))
        (self.workspace / '.pico-transfers').symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ZoomError):
            self.files.upload(self.upload())
        self.assertFalse(self.helper.uploads)
        self.assertFalse(self.gate.calls)

    def test_local_schema_is_checked_before_review_and_contact_email_is_exact(self):
        self.helper.schemas['zoom_chat_send_file']['properties']['file_paths']['type'] = 'string'
        with self.assertRaises(ZoomError):
            self.files.upload(self.upload())
        self.assertFalse(self.gate.calls)
        self.helper.schemas = copy.deepcopy(SCHEMAS)
        request = self.upload(chat_session_id=None, contact_email='resolved@example.invalid')
        result = self.files.upload(request)
        self.assertTrue(result['committed'])
        self.assertEqual(self.helper.uploads[0]['arguments']['contact_email'], 'resolved@example.invalid')
        self.assertNotIn('chat_session_id', self.helper.uploads[0]['arguments'])

    def test_download_uses_new_private_directories_and_publishes_only_actual_local_files(self):
        existing = self.workspace / 'Zoom downloads'
        existing.mkdir(mode=0o700)
        keep = existing / 'keep.txt'
        keep.write_bytes(b'Existing user file')
        original_outside = self.outside.read_bytes()
        destinations = []
        for _ in range(2):
            result = self.files.download(self.download())
            self.assertTrue(result['complete'] and result['verified'])
            self.assertEqual(result['verification_scope'], 'requested_attachment_ids_and_local_files')
            actual = {Path(row['path']) for row in result['files']}
            self.assertEqual(len(actual), 2)
            request = self.helper.downloads[-1]
            destination = Path(request['arguments']['save_dir'])
            destinations.append(destination)
            self.assertTrue(destination.is_relative_to(existing))
            self.assertEqual(request['initial_files'], [])
            self.assertEqual(request['mode'], 0o700)
            self.assertEqual(request['arguments']['file_ids'], ['observed-file-one', 'observed-file-two'])
            for row in result['files']:
                path = Path(row['path'])
                self.assertTrue(path.is_relative_to(destination))
                self.assertTrue(path.is_file())
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                self.assertEqual(row['bytes'], len(path.read_bytes()))
            self.assertEqual(set(self.artifacts[-2:]), actual)
        self.assertNotEqual(*destinations)
        self.assertEqual(keep.read_bytes(), b'Existing user file')
        self.assertEqual(self.outside.read_bytes(), original_outside)
        self.assertNotIn(self.outside, self.artifacts)
        self.assertFalse(self.gate.calls, 'A scoped requested download does not perform an external send')

    def test_same_number_of_downloaded_files_is_not_proof_of_the_requested_attachment_ids(self):
        for changed in ('wrong_ids', 'missing_ids', 'duplicate_id', 'duplicate_path', 'server_path', 'failure_status', 'failed_count'):
            with self.subTest(changed=changed):
                def corrupt(result, _destination):
                    if changed == 'wrong_ids':
                        for index, row in enumerate(result['files']): row['file_id'] = 'other-id-' + str(index)
                    elif changed == 'missing_ids':
                        for row in result['files']: row.pop('file_id')
                    elif changed == 'duplicate_id': result['files'][1]['file_id'] = result['files'][0]['file_id']
                    elif changed == 'duplicate_path': result['files'][1]['path'] = result['files'][0]['path']
                    elif changed == 'server_path': result['files'][1]['path'] = str(self.outside)
                    elif changed == 'failure_status': result['files'][1]['status'] = 'failure'
                    else: result.update(total=2, succeeded=1, failed=1, success=True)
                    return result
                self.helper.download_result = corrupt
                result = self.files.download(self.download())
                self.assertEqual(result['downloaded_count'], result['requested_count'])
                self.assertTrue(result['local_files_checked'])
                self.assertFalse(result['complete'] or result['verified'])
                self.assertEqual(result['verification_scope'], 'local_files_only')
                self.assertEqual(len(result['files']), 2)
                self.assertTrue(all(Path(row['path']).is_file() for row in result['files']))

    def test_download_identity_and_path_aliases_bind_to_actual_files(self):
        for path_key in ('file_path', 'local_path', 'saved_path', 'savePath'):
            with self.subTest(path_key=path_key):
                def alias(result, destination):
                    for row in result['files']:
                        row['fileId'] = row.pop('file_id')
                        row[path_key] = str(Path(row.pop('path')).relative_to(destination))
                        row.update(fileName=Path(row[path_key]).name, sizeBytes=(destination / row[path_key]).stat().st_size, success=True)
                    result.update(total=len(result['files']), succeeded=len(result['files']), failed=0)
                    return result
                self.helper.download_result = alias
                result = self.files.download(self.download())
                self.assertTrue(result['complete'] and result['verified'])

    def test_download_missing_or_failed_files_are_partial_not_invented_from_server_paths(self):
        self.helper.download_count = 1
        result = self.files.download(self.download())
        self.assertFalse(result['complete'] or result['verified'])
        self.assertEqual(result['requested_count'], 2)
        self.assertEqual(len(result['files']), 1)
        self.assertEqual(len(self.artifacts), 1)
        self.helper.download_count = None
        self.helper.download_result = {'success': True, 'files': [{'success': False, 'error': 'One attachment could not be fetched'}]}
        result = self.files.download(self.download())
        self.assertFalse(result['complete'] or result['verified'])
        self.assertEqual(len(result['files']), 2, 'Only real files may be published, even when the batch result is partial')

    def test_download_cannot_choose_a_destination_or_follow_local_symlinks(self):
        for request in (self.download(save_dir=str(self.root)), self.download(file_ids=['same', 'same'])):
            with self.assertRaises(ZoomError):
                self.files.download(request)
        destination = self.workspace / 'Zoom downloads'
        destination.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ZoomError):
            self.files.download(self.download())
        destination.unlink()
        self.helper.download_count = 0
        self.helper.make_symlink = self.outside
        with self.assertRaises(ZoomError) as caught:
            self.files.download(self.download(file_ids=['one']))
        self.assertEqual(caught.exception.state, 'invalid_response')
        self.assertFalse(self.artifacts)

    def test_download_rechecks_conversation_and_connection_before_publishing_results(self):
        for changed in ('generation', 'connection', 'disconnect'):
            with self.subTest(changed=changed):
                self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'private-connection'}))
                def during_download(_destination):
                    if changed == 'generation': self.gate.invalidate_pending()
                    else: self.settings.write_text(json.dumps({'enabled': changed != 'disconnect', 'connection_id': 'changed-connection'}))
                self.helper.on_download = during_download
                with self.assertRaises((ValueError, ZoomError)):
                    self.reopen().download(self.download())
                self.assertFalse(self.artifacts)


if __name__ == '__main__':
    unittest.main()
