"""Zoom's two local DevHelper file tools, confined to this conversation workspace."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import uuid

from zoom_connector import ZoomError, _json_output, _sanitize, _validate_arguments
from zoom_documents import OperationJournal, encoded, unwrap
from zoom_writes import ZoomGenericWriter


def fingerprint(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        while True:
            block = source.read(1024 * 1024)
            if not block:
                return digest.hexdigest()
            digest.update(block)


def _objects(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from _objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from _objects(child)


class LocalZoomFiles:
    def __init__(self, connector, artifact=None):
        self.zoom, self.artifact = connector, artifact

    def _workspace(self):
        self.zoom._require_enabled()
        value = getattr(self.zoom, 'workspace', None)
        if value is None:
            raise ZoomError('workspace_unavailable', 'File transfers need the current Pico conversation workspace.')
        root = Path(value).resolve(strict=True)
        if not root.is_dir():
            raise ZoomError('workspace_unavailable', 'The conversation files folder is unavailable.')
        return root

    def _schema(self, tool, arguments):
        # Local tools are separate from gateway discovery. Validate the actual
        # installed helper contract too, rather than trusting an old UI schema.
        raw = self.zoom._run_command([self.zoom._helper(), 'tool', 'schema', tool])
        schema = _json_output(raw, schema=True)
        if not isinstance(schema, dict) or schema.get('type') != 'object':
            raise ZoomError('invalid_response', 'DevHelper did not return a file-transfer input schema.')
        properties = schema.get('properties', {})
        if any(key not in properties for key in arguments):
            raise ZoomError('invalid_argument', 'File-transfer arguments do not match the installed DevHelper.')
        _validate_arguments(arguments, schema)

    @staticmethod
    def _reason(args):
        value = args.get('reason')
        if not isinstance(value, str) or not value.strip() or len(value) > 3000:
            raise ZoomError('invalid_argument', 'Describe the exact requested file transfer.')
        return value.strip()

    def _check_scope(self, connection, generation):
        self.zoom._require_enabled()
        if self.zoom._settings().get('connection_id') != connection:
            raise ZoomError('disconnected', 'The Zoom connection changed. No file was sent.')
        self.zoom.gate.check_execution(generation)

    def upload(self, args):
        root = self._workspace()
        if self.zoom.gate is None:
            raise ZoomError('approval_unavailable', 'Uploads need the current conversation authorization context.')
        if set(args) - {'chat_session_id', 'contact_email', 'file_paths', 'operation_id', 'reason'}:
            raise ZoomError('invalid_argument', 'Use the declared upload parameters only.')
        target = {key: args[key] for key in ('chat_session_id', 'contact_email') if args.get(key)}
        if len(target) != 1 or any(not isinstance(v, str) or not v.strip() or len(v) > 512 or '\n' in v or '\r' in v for v in target.values()):
            raise ZoomError('invalid_argument', 'Use one exact resolved recipient email or chat session ID.')
        paths = args.get('file_paths')
        if not isinstance(paths, list) or not 1 <= len(paths) <= 32 or any(not isinstance(p, str) for p in paths):
            raise ZoomError('invalid_argument', 'Select 1–32 existing conversation files to send.')
        sources = []
        for value in paths:
            path = Path(value)
            path = (root / path).resolve() if not path.is_absolute() else path.resolve()
            if not path.is_relative_to(root) or not path.is_file():
                raise ZoomError('invalid_argument', 'Uploads must use existing files in the current conversation files folder. Copy an explicitly selected user file there first.')
            if path in sources:
                raise ZoomError('invalid_argument', 'The same file was selected twice.')
            sources.append(path)
        operation = args.get('operation_id')
        if not isinstance(operation, str) or not re.fullmatch(r'[A-Za-z0-9_.:-]{8,128}', operation):
            raise ZoomError('invalid_argument', 'Use a unique operation_id for this exact recipient and file batch.')
        reason = self._reason(args)
        original = dict(target, file_paths=[str(p) for p in sources])
        self._schema('zoom_chat_send_file', original)
        connection = self.zoom._settings().get('connection_id')
        descriptions = [{'name': p.name, 'path': str(p), 'sha256': fingerprint(p), 'bytes': p.stat().st_size} for p in sources]
        intent = {'tool': 'zoom_chat_send_file', 'target': target, 'files': descriptions}
        digest = hashlib.sha256(encoded(intent).encode()).hexdigest()
        journal = OperationJournal(self.zoom.data)
        staging_root = root / '.pico-transfers'
        staging_root.mkdir(mode=0o700, exist_ok=True)
        if staging_root.is_symlink() or not staging_root.resolve().is_relative_to(root):
            journal.close()
            raise ZoomError('invalid_argument', 'The private upload staging folder is invalid.')
        try:
            previous = ZoomGenericWriter._previous(journal, operation, digest, connection)
            if previous is not None:
                return previous
            uncertain = journal.db.execute("SELECT id FROM operations WHERE fingerprint=? AND connection=? AND state IN ('in_flight','outcome_unknown') LIMIT 1", (digest, connection)).fetchone()
            if uncertain:
                raise ZoomError('outcome_unknown', 'An identical upload may already have reached Zoom. Inspect the chat before retrying; do not change operation_id to send again.')
            with tempfile.TemporaryDirectory(prefix='upload-', dir=staging_root) as folder:
                staged = []
                for index, source in enumerate(sources):
                    parent = Path(folder) / str(index)
                    parent.mkdir(mode=0o700)
                    dest = parent / source.name
                    shutil.copyfile(source, dest)
                    dest.chmod(0o400)
                    if fingerprint(dest) != descriptions[index]['sha256']:
                        raise ZoomError('stale_file', 'A selected file changed while preparing the upload. Nothing was sent.')
                    staged.append(dest)
                action = {'app': 'Zoom Team Chat', 'kind': 'zoom_file_upload', 'tool': 'zoom_chat_send_file',
                          'arguments': original, 'files': descriptions, 'operation_id': operation, 'reason': reason}
                reviewed = encoded(action)
                generation = self.zoom.gate.generation
                exact = self.zoom.gate.ask(action, {'connection_id': connection})
                if exact is None:
                    if ZoomGenericWriter._claim(journal, operation, digest, connection) is None:
                        journal.finish(operation, 'failed', {'state': 'denied', 'message': 'This file upload was not approved.'})
                    raise ZoomError('denied', 'This file upload was not approved.')
                if encoded(exact) != reviewed:
                    raise ZoomError('invalid_approval', 'The approved recipient or files did not match the intended upload.')
                for index, path in enumerate(sources):
                    if fingerprint(path) != descriptions[index]['sha256'] or fingerprint(staged[index]) != descriptions[index]['sha256']:
                        raise ZoomError('stale_file', 'A selected file changed after review. Nothing was sent.')
                self._check_scope(connection, generation)
                previous = ZoomGenericWriter._claim(journal, operation, digest, connection)
                if previous is not None:
                    return previous
                try:
                    self._check_scope(connection, generation)
                except (ZoomError, ValueError) as error:
                    journal.finish(operation, 'failed', {'state': getattr(error, 'state', 'superseded'),
                                   'message': 'The conversation changed before file transfer. No request was sent.'})
                    raise
                try:
                    payload = unwrap(_sanitize(_json_output(self.zoom._local_command('zoom_chat_send_file',
                                             dict(target, file_paths=[str(p) for p in staged])))))
                    rows = list(_objects(payload))
                    failed = any(row.get('success') is False or row.get('error') or str(row.get('status', '')).lower() in {'failed', 'failure', 'error'} for row in rows)
                    accepted = [row for row in rows if row.get('success') is True or str(row.get('status', '')).lower() in {'sent', 'uploaded', 'success', 'succeeded'}]
                    if failed or not accepted:
                        raise ZoomError('outcome_unknown', 'The upload may have sent some files. Inspect the exact chat before retrying; do not repeat the batch.')
                    ids = [row.get('message_id') or row.get('messageId') for row in rows if row.get('message_id') or row.get('messageId')]
                    result = {'service': 'team_chat', 'tool': 'zoom_chat_send_file', 'operation_id': operation,
                              'committed': True, 'verified': False, 'complete': False, 'replayed': False,
                              'verification_scope': 'provider_acknowledgement_only',
                              'verification': 'DevHelper accepted the upload; the recipient chat and every attachment have not been independently read back.',
                              'target': target, 'requested_files': [{'name': item['name'], 'bytes': item['bytes']} for item in descriptions],
                              'message_ids': list(dict.fromkeys(ids))}
                    journal.finish(operation, 'completed', result)
                    return result
                except (ZoomError, OSError, ValueError):
                    journal.finish(operation, 'outcome_unknown', {})
                    raise ZoomError('outcome_unknown', 'DevHelper did not confirm the complete file send. Check the chat before any retry. File transfer uses DevHelper Settings > API Token > Zoom OAuth.') from None
        finally:
            journal.close()

    def download(self, args):
        root = self._workspace()
        if set(args) - {'file_ids', 'reason'}:
            raise ZoomError('invalid_argument', 'Downloads use a new conversation folder, not a caller-selected path.')
        self._reason(args)
        ids = args.get('file_ids')
        if not isinstance(ids, list) or not 1 <= len(ids) <= 32 or any(not isinstance(v, str) or not v.strip() or len(v) > 512 for v in ids):
            raise ZoomError('invalid_argument', 'Use 1–32 observed attachment file IDs.')
        if len(set(ids)) != len(ids):
            raise ZoomError('invalid_argument', 'The same attachment was requested twice.')
        parent = root / 'Zoom downloads'
        if parent.is_symlink():
            raise ZoomError('invalid_argument', 'The download folder must belong to this conversation.')
        parent.mkdir(mode=0o700, exist_ok=True)
        if not parent.resolve().is_relative_to(root):
            raise ZoomError('invalid_argument', 'The download folder must belong to this conversation.')
        folder = parent / uuid.uuid4().hex
        folder.mkdir(mode=0o700)
        arguments = {'file_ids': ids, 'save_dir': str(folder)}
        self._schema('zoom_chat_download_file', arguments)
        self.zoom._require_enabled()
        connection = self.zoom._settings().get('connection_id')
        generation = self.zoom.gate.generation if self.zoom.gate is not None else None
        if generation is not None:
            self._check_scope(connection, generation)
        # Every destination is fresh and private: existing user files are never
        # overwritten, and a server-supplied path is not used as a destination.
        payload = unwrap(_sanitize(_json_output(self.zoom._local_command('zoom_chat_download_file', arguments))))
        self.zoom._require_enabled()
        if self.zoom._settings().get('connection_id') != connection:
            raise ZoomError('disconnected', 'The Zoom connection changed while downloading; no result was verified.')
        if generation is not None:
            self._check_scope(connection, generation)
        saved = []
        for path in folder.rglob('*'):
            if path.is_symlink() or not path.resolve().is_relative_to(folder):
                raise ZoomError('invalid_response', 'DevHelper returned an invalid downloaded-file path.')
            if path.is_file():
                path.chmod(0o600)
                saved.append({'name': path.name, 'path': str(path), 'bytes': path.stat().st_size})
                if self.artifact is not None:
                    self.artifact(path)
        rows = list(_objects(payload))
        failed = any(row.get('success') is False or row.get('error')
                     or isinstance(row.get('failed'), int) and row['failed'] > 0
                     or str(row.get('status', '')).lower() in {'error', 'failed', 'failure'} for row in rows)
        actual_paths = {item['path'] for item in saved}
        matched = {}
        for row in rows:
            file_id = row.get('file_id') or row.get('fileId')
            location = row.get('path') or row.get('file_path') or row.get('local_path') or row.get('saved_path') or row.get('savePath')
            if not isinstance(file_id, str) or file_id not in ids or not isinstance(location, str):
                continue
            path = Path(location)
            resolved = str((folder / path).resolve() if not path.is_absolute() else path.resolve())
            if resolved in actual_paths and file_id not in matched:
                matched[file_id] = resolved
        complete = (not failed and set(matched) == set(ids) and len(saved) == len(ids)
                    and len(set(matched.values())) == len(ids))
        return {'files': saved, 'verified': complete, 'complete': complete,
                'requested_count': len(ids), 'downloaded_count': len(saved), 'local_files_checked': True,
                'verification_scope': 'requested_attachment_ids_and_local_files' if complete else 'local_files_only',
                'message': 'Every requested attachment ID was matched to its downloaded file.' if complete else 'Only the listed files were checked locally; the complete set of requested attachment identities was not confirmed.'}
