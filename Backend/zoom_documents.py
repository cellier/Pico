"""Bounded Docs mutations, exact task authorization, and durable retry safety.

The journal contains hashes and sanitized operation results, never credentials or
the submitted document content. An uncertain commit is never replayed implicitly.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import time
import xml.etree.ElementTree as ET

from zoom_connector import DOCUMENT_WRITE_TOOLS, ZoomError, _json_output, _sanitize, _validate_arguments, _result_error, _failure


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))


def unwrap(value):
    for _ in range(8):
        if isinstance(value, str):
            try:
                value = json.loads(value)
            except ValueError:
                return value
        elif isinstance(value, dict) and isinstance(value.get('content'), list):
            text = [part.get('text') for part in value['content'] if isinstance(part, dict) and part.get('type') == 'text']
            if len(text) != 1:
                return value
            value = text[0]
        elif isinstance(value, dict) and not any(key in value for key in ('can_edit', 'file_id', 'file_link', 'file_name')):
            key = next((key for key in ('data', 'result') if key in value), None)
            if key is None:
                return value
            value = value[key]
        else:
            return value
    raise ZoomError('invalid_response', 'Zoom returned an unsupported document response.')


def xml_tree(value):
    if not isinstance(value, str) or not value.strip() or '<!DOCTYPE' in value.upper() or '<?' in value:
        raise ZoomError('invalid_argument', 'Use non-empty Zoom Docs XML blocks, without document declarations.')
    try:
        return ET.fromstring('<pico-root>' + value + '</pico-root>')
    except ET.ParseError:
        raise ZoomError('invalid_argument', 'The document blocks are not valid XML. Check the Zoom Docs format before writing.') from None


def text(value):
    return ' '.join(str(value).split())


CONTAINERS = {'table', 'tr', 'td', 'th', 'quote', 'callout', 'code-block', 'columns', 'column', 'page', 'database'}


def annotated_text(node):
    """Inline style nesting order is immaterial; character/style coverage is not."""
    result = []
    def add(value, styles):
        for character in value or '':
            if not character.isspace():
                result.append((character, tuple(sorted(styles))))
    def visit(current, styles, root=False):
        if not root:
            style = (current.tag, tuple(sorted((key, value) for key, value in current.attrib.items() if key not in ('id', 'block_id'))))
            styles = styles + (style,)
        if not root and not len(current) and not current.text:
            # A line break, date mention, timer or empty media node carries
            # semantics even without text. Keep its attributes and position.
            result.append(('\x00', tuple(sorted(styles))))
        add(current.text, styles)
        for child in current:
            visit(child, styles)
            add(child.tail, styles)
    visit(node, (), True)
    return result


def leaf_matches(expected, actual):
    if expected.tag != actual.tag or any(node.tag in CONTAINERS for node in expected.iter()):
        return False
    attrs = {key: value for key, value in expected.attrib.items() if key not in ('id', 'block_id')}
    return (all(actual.get(key) == value for key, value in attrs.items())
            and text(''.join(expected.itertext())) == text(''.join(actual.itertext()))
            and annotated_text(expected) == annotated_text(actual))


def has_commit_ack(tool, payload):
    if not isinstance(payload, dict):
        return False
    if tool == 'docs_file_create_with_content':
        return isinstance(payload.get('file_id', payload.get('fileId')), str) and bool(payload.get('file_id', payload.get('fileId')).strip())
    return (payload.get('success') is True or payload.get('status') in ('success', 'ok')
            or type(payload.get('code')) is int and payload['code'] in (0, 200)
            or any(payload.get(key) for key in ('file_id', 'fileId', 'block_id', 'block_ids', 'updated_block_id', 'inserted_block_ids')))


def operation_summary(value):
    payload = unwrap(value)
    if not isinstance(payload, dict):
        return {}
    # Do not retain an API's echoed document body in the retry journal or send
    # a potentially megabyte-sized body through the model tool transcript.
    keys = ('file_id', 'fileId', 'file_link', 'file_name', 'block_id', 'block_ids',
            'updated_block_id', 'inserted_block_ids', 'success', 'code', 'status')
    return {key: payload[key] for key in keys if key in payload}


class OperationJournal:
    def __init__(self, directory):
        directory = Path(directory)
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = directory / 'zoom-doc-operations.sqlite'
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT, 0o600)
        os.close(fd)
        self.path.chmod(0o600)
        self.db = sqlite3.connect(self.path, timeout=10)
        self.db.execute('CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, connection TEXT NOT NULL, state TEXT NOT NULL, result TEXT, updated REAL NOT NULL)')
        self.db.commit()

    def close(self):
        self.db.close()

    def existing(self, operation, fingerprint, connection):
        row = self.db.execute('SELECT fingerprint,connection,state,result FROM operations WHERE id=?', (operation,)).fetchone()
        if row is None:
            return None
        if row[0] != fingerprint or row[1] != connection:
            raise ZoomError('operation_conflict', 'This operation_id already refers to different content or a different Zoom connection. Do not reuse it for another change.')
        if row[2] in ('in_flight', 'outcome_unknown'):
            raise ZoomError('outcome_unknown', 'The previous write may have reached Zoom. Do not repeat it or change operation_id to retry. Read the document or search the created file first to establish its actual state.')
        result = json.loads(row[3])
        if row[2] == 'failed':
            raise ZoomError(result['state'], result['message'])
        return dict(result, replayed=True)

    def claim(self, operation, fingerprint, connection):
        self.db.execute('BEGIN IMMEDIATE')
        try:
            previous = self.existing(operation, fingerprint, connection)
            if previous is None:
                self.db.execute('INSERT INTO operations VALUES (?,?,?,?,?,?)', (operation, fingerprint, connection, 'in_flight', None, time.time()))
            self.db.commit()
            return previous
        except BaseException:
            self.db.rollback()
            raise

    def finish(self, operation, state, result):
        self.db.execute('UPDATE operations SET state=?,result=?,updated=? WHERE id=?', (state, encoded(result), time.time(), operation))
        self.db.commit()


class ZoomDocumentWriter:
    def __init__(self, connector):
        self.zoom = connector

    def read_document(self, file_id):
        args = {'service': 'docs', 'tool': 'docs_file_get_content', 'arguments': {'file_id': file_id, 'format': 'xml'}}
        result = self.zoom.read(args)
        if result.get('truncated'):
            parts = [result['content_excerpt']]
            offset = result.get('next_output_offset')
            while offset is not None:
                result = self.zoom.read(dict(args, output_offset=offset))
                parts.append(result['content_excerpt'])
                following = result.get('next_output_offset')
                if following is not None and following <= offset:
                    raise ZoomError('invalid_response', 'Zoom document response did not advance.')
                offset = following
            try:
                payload = json.loads(''.join(parts))
            except ValueError:
                raise ZoomError('invalid_response', 'Zoom did not return the complete document.') from None
        else:
            payload = result.get('result')
        payload = unwrap(payload)
        if not isinstance(payload, dict) or not isinstance(payload.get('content'), str):
            raise ZoomError('invalid_response', 'Zoom did not return readable document content. No edit was attempted.')
        return payload

    @staticmethod
    def base_hash(document):
        # Ignore transport tracking IDs and permission metadata that do not
        # describe the content the user is authorizing us to change.
        return hashlib.sha256(encoded({key: document.get(key) for key in ('content', 'file_name')}).encode()).hexdigest()

    @staticmethod
    def check_targets(tool, arguments, document):
        if document.get('can_edit') is not True:
            raise ZoomError('permission_denied', 'Zoom has not confirmed edit permission for this document. Its content was not changed.')
        if tool == 'docs_file_modify_metadata':
            if not arguments.get('file_name', '').strip():
                raise ZoomError('invalid_argument', 'Specify the new document name.')
            return
        root = xml_tree(document['content'])
        nodes = {node.get('block_id', node.get('id')): node for node in root.iter() if node.get('block_id', node.get('id'))}
        parents = {child: parent for parent in root.iter() for child in parent}
        ids = []
        if tool == 'docs_file_update_block':
            ids = [arguments['block_id']]
        elif tool == 'docs_file_replace_range_of_blocks':
            ids = [arguments['start_block_id'], arguments['end_block_id']]
        else:
            positioning = arguments.get('positioning', {})
            if (not isinstance(positioning, dict) or len(positioning) > 1
                    or any(key not in ('above_block_id', 'below_block_id', 'parent_block_id') for key in positioning)):
                raise ZoomError('invalid_argument', 'Choose at most one insertion position.')
            ids = list(positioning.values())
        if any(identity not in nodes for identity in ids):
            raise ZoomError('stale_document', 'Use full block IDs from a fresh XML read of this document. No edit was attempted.')
        if tool == 'docs_file_replace_range_of_blocks':
            first, last = (nodes[identity] for identity in ids)
            parent = parents.get(first)
            if parent is None or parent is not parents.get(last) or list(parent).index(first) > list(parent).index(last):
                raise ZoomError('invalid_argument', 'Replacement endpoints must be ordered sibling blocks.')
        if tool == 'docs_file_update_block':
            target = nodes[ids[0]]
            # The server defines container support. Block-bearing descendants
            # and atomic tables are enough to reject dangerous inner edits here.
            if target.tag in CONTAINERS or any(node is not target and (node.get('block_id') or node.get('id')) for node in target.iter()):
                raise ZoomError('invalid_argument', 'Use a complete container replacement for this block, preserving its unaffected content.')
            submitted = list(xml_tree(arguments['block']))
            if len(submitted) != 1 or submitted[0].tag != target.tag:
                raise ZoomError('invalid_argument', 'Update exactly one leaf block and preserve its existing block type.')
        if any(nodes[identity].tag in ('tr', 'td', 'th') for identity in ids):
            raise ZoomError('invalid_argument', 'Tables are atomic. Replace the complete table rather than individual rows or cells.')

    def verify(self, tool, arguments, api_result, verification_text, baseline=None):
        payload = unwrap(api_result)
        file_id = arguments.get('file_id', arguments.get('id'))
        if tool == 'docs_file_create_with_content' and isinstance(payload, dict):
            file_id = payload.get('file_id', payload.get('fileId'))
        result = {'committed': has_commit_ack(tool, payload), 'verified': False, 'verification': 'read_back_unavailable',
                  'file_id': file_id, 'result': api_result,
                  'notice': 'Zoom accepted the write. Do not repeat it merely because verification is incomplete.'}
        if isinstance(payload, dict) and isinstance(payload.get('file_link'), str):
            result['file_link'] = payload['file_link']
        if not isinstance(file_id, str) or not file_id:
            return result
        try:
            document = self.read_document(file_id)
            if isinstance(document.get('file_link'), str):
                result['file_link'] = document['file_link']
            result['read_back'] = {'file_name': document.get('file_name'), 'available': True}
            if tool == 'docs_file_modify_metadata':
                matched = document.get('file_name') == arguments['file_name']
            else:
                fresh_root = xml_tree(document['content'])
                body = text(' '.join(fresh_root.itertext()))
                if tool == 'docs_file_create_with_content':
                    matched = result['committed'] and bool(verification_text) and all(text(marker) in body for marker in verification_text)
                    if not arguments.get('content', '').strip():
                        matched = result['committed'] and not body
                elif tool == 'docs_file_update_block':
                    expected = list(xml_tree(arguments['block']))[0]
                    target = next((node for node in fresh_root.iter() if node.get('block_id', node.get('id')) == arguments['block_id']), None)
                    matched = target is not None and leaf_matches(expected, target)
                else:
                    expected = list(xml_tree(arguments['blocks']))
                    old_root = xml_tree(baseline['content'])
                    # Counting matching new leaf blocks prevents an unrelated
                    # old marker elsewhere from making a no-op look verified.
                    removed = []
                    if tool == 'docs_file_replace_range_of_blocks':
                        nodes = {node.get('block_id', node.get('id')): node for node in old_root.iter() if node.get('block_id', node.get('id'))}
                        first, last = nodes[arguments['start_block_id']], nodes[arguments['end_block_id']]
                        parent = next(node for node in old_root.iter() if first in list(node))
                        siblings = list(parent)
                        removed = siblings[siblings.index(first):siblings.index(last) + 1]
                    matched = True
                    for index, block in enumerate(expected):
                        copies = sum(leaf_matches(block, other) for other in expected)
                        before = sum(leaf_matches(block, node) for node in old_root.iter())
                        after = sum(leaf_matches(block, node) for node in fresh_root.iter())
                        removed_count = sum(leaf_matches(block, node) for root in removed for node in root.iter())
                        if after < before - removed_count + copies or any(node.tag in CONTAINERS for node in block.iter()):
                            matched = False
                            break
                    if verification_text:
                        matched = matched and all(text(marker) in body for marker in verification_text)
                    # Full-document counts establish that submitted content is
                    # present, not that the API put it at the intended sibling
                    # position or removed exactly the requested old range.
                    result['content_observed'] = matched
                    result['verification_scope'] = 'position_and_structure_need_review'
                    matched = False
            result.update(verified=matched, verification='verified' if matched else 'content_not_verified')
            if matched:
                result['committed'] = True
                result['verification_scope'] = 'document_name' if tool == 'docs_file_modify_metadata' else 'submitted_leaf_content' if tool != 'docs_file_create_with_content' else 'expected_text'
                result.pop('notice', None)
        except (ZoomError, ValueError, TypeError):
            pass
        return result

    def write(self, args):
        self.zoom._require_enabled()
        service = self.zoom._identifier(args.get('service'))
        tool = self.zoom._identifier(args.get('tool'))
        if service != 'docs' or tool not in DOCUMENT_WRITE_TOOLS:
            raise ZoomError('read_only', 'Only the listed Zoom Docs creation, content edit and rename operations are enabled. This operation was not called.')
        if self.zoom.gate is None:
            raise ZoomError('approval_unavailable', 'Zoom writes require Pico\'s task authorization context.')
        arguments = args.get('arguments')
        if not isinstance(arguments, dict):
            raise ZoomError('invalid_argument', 'Use arguments matching zoom_schema.')
        # Deep copy once; mutable caller data must not change what was reviewed.
        arguments = json.loads(encoded(arguments))
        operation = args.get('operation_id')
        if not isinstance(operation, str) or not re.fullmatch(r'[A-Za-z0-9_.:-]{8,128}', operation):
            raise ZoomError('invalid_argument', 'Use a unique operation_id (UUID recommended) and reuse it only for an identical retry.')
        reason = args.get('reason')
        if not isinstance(reason, str) or not reason.strip():
            raise ZoomError('invalid_argument', 'Describe the requested document change.')
        markers = args.get('verification_text', [])
        if not isinstance(markers, list) or len(markers) > 16 or any(not isinstance(marker, str) or not marker.strip() or len(marker) > 500 for marker in markers):
            raise ZoomError('invalid_argument', 'verification_text accepts up to 16 distinctive non-empty text snippets, each at most 500 characters.')
        if len(encoded(arguments).encode()) > 160000:
            raise ZoomError('invalid_argument', 'The document change is too large for one request. Split it into focused sections; no content was truncated or sent.')
        connection = self.zoom._settings().get('connection_id')
        if not isinstance(connection, str) or not connection:
            raise ZoomError('disconnected', 'Reconnect Zoom in Pico before editing documents.')
        fingerprint = hashlib.sha256(encoded({'service': service, 'tool': tool, 'arguments': arguments, 'verification_text': markers}).encode()).hexdigest()
        journal = OperationJournal(self.zoom.data)
        try:
            previous = journal.existing(operation, fingerprint, connection)
            if previous is not None:
                return previous
            metadata = self.zoom._schema(service, tool)
            schema = metadata['inputSchema']
            _validate_arguments(arguments, schema)
            if any(key not in schema.get('properties', {}) for key in arguments):
                raise ZoomError('invalid_argument', 'Only exact parameters from the current Zoom write schema are allowed.')
            for name in schema.get('required', []):
                if name not in arguments:
                    raise ZoomError('invalid_argument', 'Missing required Zoom argument: ' + name)
            document = None
            file_id = arguments.get('file_id', arguments.get('id'))
            if tool != 'docs_file_create_with_content':
                if not isinstance(file_id, str) or not file_id or '://' in file_id:
                    raise ZoomError('invalid_argument', 'Use the exact document ID, not its URL.')
                document = self.read_document(file_id)
                self.check_targets(tool, arguments, document)
                if tool != 'docs_file_modify_metadata':
                    blocks = arguments.get('blocks', arguments.get('block'))
                    if not list(xml_tree(blocks)):
                        raise ZoomError('invalid_argument', 'Provide non-empty replacement blocks, not a deletion.')
            submitted = arguments.get('content', '') if tool == 'docs_file_create_with_content' else arguments.get('blocks', arguments.get('block', ''))
            if tool != 'docs_file_modify_metadata':
                plain = text(submitted) if tool == 'docs_file_create_with_content' else text(' '.join(xml_tree(submitted).itertext()))
                markdown_plain = text(re.sub(r'[*_#`>~\[\]()]', '', submitted)) if tool == 'docs_file_create_with_content' else plain
                if any(text(marker) not in plain and text(marker) not in markdown_plain for marker in markers):
                    raise ZoomError('invalid_argument', 'Verification snippets must come from the content being submitted, not unrelated existing text.')
            action = {'app': 'Zoom Docs', 'kind': 'zoom_document_write', 'reason': reason,
                      'service': service, 'tool': tool, 'arguments': arguments,
                      'operation_id': operation, 'verification_text': markers}
            context = {'connection_id': connection, 'base_sha256': self.base_hash(document) if document else None}
            generation = getattr(self.zoom.gate, 'generation', None)
            reviewed = encoded(action)
            exact = self.zoom.gate.ask(action, context)
            if exact is None:
                if journal.claim(operation, fingerprint, connection) is None:
                    journal.finish(operation, 'failed', {'state': 'denied', 'message': 'The document change was not approved. Do not retry without a new user request.'})
                raise ZoomError('denied', 'The document change was not approved. Do not retry without a new user request.')
            if encoded(exact) != reviewed:
                raise ZoomError('invalid_approval', 'The approved document operation did not match the requested content. Nothing was sent.')
            self.zoom._require_enabled()
            if self.zoom._settings().get('connection_id') != connection:
                raise ZoomError('disconnected', 'The Zoom connection changed while reviewing this edit. Nothing was sent.')
            if document is not None:
                fresh = self.read_document(file_id)
                self.check_targets(tool, arguments, fresh)
                if self.base_hash(fresh) != self.base_hash(document):
                    raise ZoomError('stale_document', 'The document changed while reviewing the edit. Read it again before proposing a new change.')
            if hasattr(self.zoom.gate, 'check_execution'):
                self.zoom.gate.check_execution(generation)
            previous = journal.claim(operation, fingerprint, connection)
            if previous is not None:
                return previous
            try:
                self.zoom._require_enabled()
                if self.zoom._settings().get('connection_id') != connection:
                    raise ZoomError('disconnected', 'The Zoom connection changed before submission. Nothing was sent.')
                if hasattr(self.zoom.gate, 'check_execution'):
                    self.zoom.gate.check_execution(generation)
            except BaseException:
                journal.finish(operation, 'failed', {'state': 'superseded', 'message': 'This edit was superseded before submission. Nothing was sent.'})
                raise
            try:
                raw = self.zoom._command([service, tool, '--args-json', encoded(exact['arguments'])])
            except ZoomError as error:
                self.zoom._read_cache.clear()
                if error.state in ('needs_login', 'permission_denied', 'missing_helper'):
                    journal.finish(operation, 'failed', {'state': error.state, 'message': str(error)})
                    self.zoom._remember_error(error)
                    raise
                journal.finish(operation, 'outcome_unknown', {})
                raise ZoomError('outcome_unknown', 'Zoom did not confirm the document write. It may already have been applied. Read or search the document before retrying; do not submit it again automatically.') from None
            try:
                api_result = _sanitize(_json_output(raw))
                if _result_error(unwrap(api_result)):
                    raise _failure(encoded(unwrap(api_result)))
            except ZoomError as error:
                state = 'failed' if error.state in ('needs_login', 'permission_denied') else 'outcome_unknown'
                journal.finish(operation, state, {'state': error.state, 'message': str(error)})
                if state == 'outcome_unknown':
                    raise ZoomError('outcome_unknown', 'Zoom returned an unverified write result. Read the document before retrying; it may already exist or contain the change.') from None
                self.zoom._remember_error(error)
                raise
            self.zoom._read_cache.clear()
            self.zoom._verified(service, read=False)
            result = dict(self.verify(tool, arguments, api_result, markers, document), service=service,
                          tool=tool, operation_id=operation, replayed=False, untrusted=True)
            if not result['committed']:
                journal.finish(operation, 'outcome_unknown', {})
                raise ZoomError('outcome_unknown', 'Zoom did not provide a confirmed write result and the intended change could not be read back. Do not repeat the write; inspect or search the document first.')
            result['result'] = operation_summary(api_result)
            # A successful commit is durable even if its readback failed. Reusing
            # operation_id returns this same commit rather than creating twice.
            journal.finish(operation, 'completed', result)
            return result
        finally:
            journal.close()
