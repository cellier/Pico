"""Pico's narrow, profile-isolated bridge to Hermes hosted app connectors.

The parent owns approval and durable write deduplication. This module never
copies another client's credentials, enables a toolset, or claims readback from
an execute acknowledgement. Only status/connect are public CLI actions.
Hermes seams below match the reviewed 0.22.0 runtime (e06df9c2).
"""
from __future__ import annotations

import argparse
import contextlib
import json
import logging
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

APPS = {
    'gmail': ('Gmail', ('gmail',)),
    'twitter': ('X / Twitter', ('twitter', 'x', 'twitter_v2', 'x_twitter')),
    'notion': ('Notion', ('notion',)),
    'figma': ('Figma', ('figma',)),
}
MAX_INPUT = 262_144
MAX_OUTPUT = 2_000_000
ENV_KEYS = frozenset(('PATH', 'HOME', 'USER', 'LANG', 'LC_ALL', 'TMPDIR', 'SHELL'))
TIMEOUTS = {'status': 65, 'connect': 65, 'search': 65, 'describe': 65, 'call': 100}


class ConnectedAppError(Exception):
    def __init__(self, code, message, *, outcome_unknown=False):
        self.code, self.message, self.outcome_unknown = code, message, outcome_unknown
        super().__init__(message)


def _error(code, message, *, outcome_unknown=False):
    result = {'error': {'code': code, 'message': message}}
    if outcome_unknown:
        result['outcome_unknown'] = True
    return result


def _safe_error(value):
    """Exception text is never a transport for credentials or authorization URLs."""
    text = str(value)
    text = re.sub(r'https?://[^\s<>"\']+', '[service link omitted]', text)
    text = re.sub(r'(?i)\bauthorization["\']?\s*[:=]?\s*["\']?(?:bearer\s+|basic\s+)?[^,;\r\n]+', '[credential omitted]', text)
    text = re.sub(r'(?i)\b(?:bearer|basic)\s+[^\s,;]+', '[credential omitted]', text)
    text = re.sub(r'(?i)\b(?:(?:access|refresh|id)[_-]?token|client[_-]?secret|token|secret|api[_ -]?key)["\']?\s*[:=]\s*["\']?[^\s,;"\']+', '[credential omitted]', text)
    return text[:350]


def _apps(args):
    raw = args.get('connectors', args.get('apps', list(APPS)))
    if not isinstance(raw, list) or not 1 <= len(raw) <= 4:
        raise ConnectedAppError('invalid_argument', 'Choose between one and four supported apps.')
    result = []
    for value in raw:
        key = 'twitter' if value in ('x', 'twitter') else value
        if not isinstance(key, str) or key not in APPS:
            raise ConnectedAppError('invalid_argument', 'Supported apps are Gmail, X / Twitter, Notion and Figma.')
        if key not in result:
            result.append(key)
    return result


def _selected_apps(action, args):
    """Content tools inspect only the accounts named by their exact tool names."""
    if action not in ('describe', 'call'):
        return _apps(args)
    names = args.get('names') if action == 'describe' else [args.get('name')]
    if not isinstance(names, list) or not 1 <= len(names) <= 10 or not all(isinstance(n, str) for n in names) or len(set(names)) != len(names):
        raise ConnectedAppError('invalid_argument', 'Choose exact tool names returned by app search.')
    aliases = {alias: key for key, (_, values) in APPS.items() for alias in values}
    selected = []
    for name in names:
        parts = name.split('__', 2)
        if len(name) > 260 or len(parts) != 3 or parts[0] != 'connectors' or not parts[2]:
            raise ConnectedAppError('invalid_argument', 'Choose an exact tool returned by app search.')
        if parts[1] not in aliases:
            raise ConnectedAppError('unsupported_app', 'This tool is outside the four connected apps.')
        key = aliases[parts[1]]
        if key not in selected:
            selected.append(key)
    return selected


def _connect_url(value):
    if not isinstance(value, str) or len(value) > 16_384 or any(ord(c) < 33 for c in value):
        return None
    try:
        parsed = urlsplit(value)
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
            return None
        # Links are supplied only by the authenticated official connector gateway.
        # Do not guess provider OAuth hostnames: vendors may use a connection broker.
        return value
    except ValueError:
        return None


def _accounts(value):
    if not isinstance(value, list):
        return []
    result = []
    for row in value[:20]:
        if not isinstance(row, dict):
            continue
        result.append({key: row[key] for key in ('alias', 'label', 'status', 'active', 'retired')
                       if key in row and isinstance(row[key], (str, bool, type(None)))})
    return result


def _parse(value):
    if isinstance(value, str):
        value = json.loads(value)
    if not isinstance(value, dict):
        raise ConnectedAppError('invalid_response', 'The app service returned an invalid response.')
    if value.get('error'):
        error = value['error']
        detail = error.get('message') if isinstance(error, dict) else error
        raise ConnectedAppError('service_error', _safe_error(detail))
    return value


class _Hermes:
    """Pinned public connector facade; no CLI startup, plugin scan or dotenv import."""
    def identity(self):
        from hermes_cli.auth import get_provider_auth_state
        return bool(get_provider_auth_state('nous'))

    def provision(self):
        from tools.connectors.gateway.config import ensure_guest_identity
        error = ensure_guest_identity()
        if error:
            raise ConnectedAppError('connection_setup_failed', _safe_error(error))

    def status(self):
        from tools.connectors import manage_connections
        return _parse(manage_connections({'action': 'status'}))

    def connect(self, slugs):
        from tools.connectors import manage_connections
        return _parse(manage_connections({'action': 'connect', 'connectors': slugs}))

    def search(self, query):
        from tools.connectors import connector_search_hits
        leg = connector_search_hits([{'use_case': query}])
        if leg.failure:
            raise ConnectedAppError('service_unavailable', 'App search is unavailable; reconnect or try again later.')
        return leg.payload

    def describe(self, names):
        from tools.connectors import connector_describe
        leg = connector_describe(names)
        if leg.failure:
            raise ConnectedAppError('service_unavailable', 'App tool details are unavailable.')
        return leg.payload

    def facets(self, slug):
        # Portal metadata is the authoritative read/write classification. The
        # public describe facade intentionally does not carry these fields.
        from tools.connectors.portal.client import PortalConnectorClient
        listing = PortalConnectorClient().tools(slug)
        return {row.slug: row.facet for row in listing.tools}

    def catalogue(self, slug):
        from tools.connectors.portal.client import PortalConnectorClient
        listing = PortalConnectorClient().tools(slug)
        return {row.slug: {'description': row.description, 'facet': row.facet} for row in listing.tools}

    def raw_schema(self, name):
        from tools.connectors.gateway.client import ConnectorClient
        from tools.connectors.gateway.names import parse_connector_name, vendor_slug_candidates
        parsed = parse_connector_name(name)
        candidates = vendor_slug_candidates(parsed.connector, parsed.tool)
        schemas = ConnectorClient().schemas(candidates).get('schemas') or {}
        selected = next((schemas[slug] for slug in candidates if isinstance(schemas.get(slug), dict)), None)
        if selected is None or not isinstance(selected.get('input_schema'), dict):
            raise ConnectedAppError('tool_not_found', 'The current app schema could not be checked; nothing was executed.')
        return selected['input_schema']

    def call(self, name, arguments, operation_id=None):
        from tools.connectors import dispatch_connector_call
        value = dispatch_connector_call(name, arguments, operation_id)
        return json.loads(value) if isinstance(value, str) else value


def _directory(rows):
    if not isinstance(rows, list):
        raise ConnectedAppError('invalid_response', 'The app directory is unavailable.')
    by_slug = {row.get('connector'): row for row in rows if isinstance(row, dict)}
    return {key: next((by_slug[slug] for slug in aliases if slug in by_slug), None)
            for key, (_, aliases) in APPS.items()}


def _app_rows(selected, directory=None, *, identity=False):
    rows = []
    for key in selected:
        source = (directory or {}).get(key)
        connected = bool(source and source.get('connected') is True)
        row = {'id': key, 'name': APPS[key][0], 'state': 'connected' if connected else
               'unavailable' if identity and source is None else 'disconnected', 'connected': connected}
        if source:
            row['connector'] = source['connector']
            row['accounts'] = _accounts(source.get('accounts'))
            row['provider'] = source.get('provider', 'hermes')
            if source.get('state') in ('needs_authorization', 'not_installed', 'unavailable', 'disconnected') and not connected:
                row['state'] = source['state']
            if isinstance(source.get('detail'), str):
                row['detail'] = _safe_error(source['detail'])
        if not identity:
            row['detail'] = 'Not connected. Choose Connect to authorize this app for Pico.'
        elif source is None and key == 'twitter':
            row['detail'] = 'X / Twitter needs your own X developer app and user-completed xurl authorization. It is not connected.'
        elif source is None:
            row['detail'] = 'This app is not available in the current Hermes connector directory.'
        rows.append(row)
    return rows


def _tool_name(name, directory):
    if not isinstance(name, str) or len(name) > 260:
        raise ConnectedAppError('invalid_argument', 'Choose an exact tool returned by app search.')
    parts = name.split('__', 2)
    if len(parts) != 3 or parts[0] != 'connectors' or not all(parts[1:]):
        raise ConnectedAppError('invalid_argument', 'Choose an exact tool returned by app search.')
    allowed = {row['connector']: key for key, row in directory.items() if row}
    if parts[1] not in allowed:
        raise ConnectedAppError('unsupported_app', 'This tool is outside the four connected apps.')
    return parts[1], parts[2], allowed[parts[1]]


def _local_references(schema):
    """Schema validation never fetches an arbitrary external $ref URL."""
    if isinstance(schema, dict):
        for key, value in schema.items():
            if key in ('$ref', '$dynamicRef', '$recursiveRef') and (not isinstance(value, str) or not value.startswith('#')):
                raise ConnectedAppError('unsupported_schema', 'This tool uses an external schema reference; nothing was executed.')
            _local_references(value)
    elif isinstance(schema, list):
        for value in schema:
            _local_references(value)


def _uses_file_inputs(schema, arguments, root=None, depth=0):
    """Refuse supplied uploads while allowing ordinary actions with optional files."""
    if depth > 48:
        raise ConnectedAppError('unsupported_schema', 'The file input schema is too deeply nested; nothing was executed.')
    if not isinstance(schema, dict):
        return False
    root = schema if root is None else root
    if schema.get('file_uploadable') is True and arguments not in (None, '', [], {}):
        return True
    ref = schema.get('$ref')
    if isinstance(ref, str):
        rule = root
        try:
            if ref != '#':
                if not ref.startswith('#/'):
                    raise KeyError(ref)
                for part in ref[2:].split('/'):
                    rule = rule[part.replace('~1', '/').replace('~0', '~')]
        except (KeyError, TypeError):
            raise ConnectedAppError('unsupported_schema', 'The file input schema could not be resolved; nothing was executed.') from None
        if _uses_file_inputs(rule, arguments, root, depth + 1):
            return True
    for group in ('anyOf', 'oneOf', 'allOf'):
        if any(_uses_file_inputs(branch, arguments, root, depth + 1) for branch in schema.get(group, [])):
            return True
    if isinstance(arguments, dict):
        properties = schema.get('properties') or {}
        for key, value in arguments.items():
            rule = properties.get(key, schema.get('additionalProperties', {}))
            if _uses_file_inputs(rule, value, root, depth + 1):
                return True
    elif isinstance(arguments, list):
        for value in arguments:
            if _uses_file_inputs(schema.get('items', {}), value, root, depth + 1):
                return True
    return False


def _describe(hermes, names, directory):
    described = _parse(hermes.describe(names)).get('tools', {})
    facets = {}
    tools = {}
    for name in names:
        slug, tool, key = _tool_name(name, directory)
        metadata = described.get(name)
        if not isinstance(metadata, dict) or not isinstance(metadata.get('parameters'), dict):
            raise ConnectedAppError('tool_not_found', 'The selected app tool is no longer available.')
        if slug not in facets:
            facets[slug] = hermes.facets(slug)
        # Follow Hermes's exact prefixed-first name resolution, not a substring.
        facet = facets[slug].get(f'{slug.upper()}_{tool}', facets[slug].get(tool, 'unclassified'))
        if facet not in ('read', 'write', 'destructive', 'unclassified'):
            facet = 'unclassified'
        tools[name] = {'description': str(metadata.get('description', ''))[:12_000],
                       'parameters': metadata['parameters'], 'facet': facet,
                       'accounts': _accounts(directory[key].get('accounts')), 'provider': 'hermes'}
    return {'tools': tools}


def _fallback_request(provider, method, *args):
    try:
        value = getattr(provider, method)(*args)
        if method == 'status' and isinstance(value, dict) and isinstance(value.get('connected'), bool):
            return value  # status can carry a useful unavailable/needs-authorization error
        return _parse(value)
    except ConnectedAppError:
        raise
    except Exception as exc:
        code = getattr(exc, 'code', 'fallback_unavailable')
        code = code if isinstance(code, str) and re.fullmatch(r'[A-Za-z0-9_]{1,80}', code) else 'fallback_unavailable'
        raise ConnectedAppError(code, _safe_error(getattr(exc, 'message', 'The connected app service is unavailable.')),
                                outcome_unknown=bool(getattr(exc, 'outcome_unknown', False))) from None


def _fallback_provider(data, workspace):
    if data is None:
        return None
    try:
        from devhelper_apps import DevHelperApps
        return DevHelperApps(data, workspace=workspace)
    except ImportError:
        return None


def _x_provider(data, workspace):
    if data is None:
        return None
    try:
        from x_apps import XApps
        return XApps(data, workspace=workspace)
    except ImportError:
        return None


def _combined_describe(hermes, fallback, names, directory, xprovider=None):
    hosted, external = [], {'devhelper': [], 'xurl': []}
    for name in names:
        _, _, key = _tool_name(name, directory)
        provider = directory[key].get('provider')
        (external[provider] if provider in external else hosted).append(name)
    tools = _describe(hermes, hosted, directory)['tools'] if hosted else {}
    for provider_name, selected in external.items():
        if not selected:
            continue
        provider = fallback if provider_name == 'devhelper' else xprovider
        if provider is None:
            raise ConnectedAppError('service_unavailable', 'The app provider is unavailable.')
        payload = _fallback_request(provider, 'describe', selected).get('tools') or {}
        for name in selected:
            _, _, key = _tool_name(name, directory)
            metadata = payload.get(name)
            if not isinstance(metadata, dict) or not isinstance(metadata.get('parameters'), dict):
                raise ConnectedAppError('tool_not_found', 'The selected app tool is unavailable.')
            actual_accounts = _accounts(metadata.get('accounts'))
            if not directory[key].get('connected') or not actual_accounts:
                raise ConnectedAppError('not_connected', 'Authorize this app before using its content tools.')
            if actual_accounts != _accounts(directory[key].get('accounts')):
                raise ConnectedAppError('account_changed', 'The connected app account changed. Inspect its current account before continuing.')
            facet = metadata.get('facet')
            tools[name] = {'description': str(metadata.get('description', ''))[:12_000],
                           'parameters': metadata['parameters'],
                           'facet': facet if facet in ('read', 'write', 'destructive') else 'unclassified',
                           'accounts': actual_accounts, 'provider': provider_name}
    return {'tools': tools}


def _catalogue_search(hermes, slugs, query):
    """Supplement semantic search from official tool metadata, never account content."""
    if not hasattr(hermes, 'catalogue'):
        return {}
    lowered = query.casefold()
    terms = {word for word in re.findall(r'[\w]+', lowered.replace('_', ' '))
             if len(word) > 1 and word not in {'notion', 'gmail', 'figma', 'twitter', 'get', 'the', 'and', 'for', 'from', 'with'}}
    ranked = []
    for slug in sorted(slugs):
        try:
            catalogue = hermes.catalogue(slug)
        except Exception:
            continue  # Semantic results remain usable if only this metadata route is down.
        if not isinstance(catalogue, dict):
            continue
        for vendor_name, metadata in catalogue.items():
            if not isinstance(vendor_name, str) or not isinstance(metadata, dict):
                continue
            short = vendor_name.removeprefix(f'{slug.upper()}_')
            name = f'connectors__{slug}__{short}'
            description = str(metadata.get('description', ''))
            words = set(re.findall(r'[\w]+', (vendor_name + ' ' + description).casefold().replace('_', ' ')))
            exact = vendor_name.casefold() in lowered or name.casefold() in lowered or (len(short) >= 5 and short.casefold() in lowered)
            score = (10000 if exact else 0) + 10 * len(terms & words)
            if not score:
                continue
            facet = metadata.get('facet')
            ranked.append((-score, name, {'description': description[:2000],
                           'facet': facet if facet in ('read', 'write', 'destructive') else 'unclassified'}))
    ranked.sort(key=lambda item: (item[0], item[1]))
    return {name: metadata for _, name, metadata in ranked[:30]}


def _dispatch(action, args, hermes=None, *, fallback=None, xprovider=None, data=None, workspace=None):
    if not isinstance(args, dict):
        raise ConnectedAppError('invalid_argument', 'App arguments must be a JSON object.')
    if action not in TIMEOUTS:
        raise ConnectedAppError('invalid_argument', 'Unknown connected app action.')
    if action == 'connect' and not ('connectors' in args or 'apps' in args):
        raise ConnectedAppError('invalid_argument', 'Choose the app accounts to connect.')
    hermes = hermes or _Hermes()
    fallback = fallback if fallback is not None else _fallback_provider(data, workspace)
    xprovider = xprovider if xprovider is not None else _x_provider(data, workspace)
    providers = {'devhelper': fallback, 'xurl': xprovider}
    routes = {key: ('devhelper', fallback) for key in ('gmail', 'figma') if fallback is not None}
    if xprovider is not None:
        routes['twitter'] = ('xurl', xprovider)
    selected = _selected_apps(action, args)
    identity = hermes.identity()
    # Mere Settings opening is never a request to create a remote identity.
    if not identity and action == 'status' and not routes:
        return {'identity_state': 'not_connected', 'apps': _app_rows(selected)}
    if not identity and action not in ('connect', 'status') and not routes:
        raise ConnectedAppError('not_connected', 'Connect this app in Pico Settings first.')
    if action == 'connect' and not identity and ('notion' in selected or not routes):
        hermes.provision()
        identity = True
    status = _parse(hermes.status()) if identity else {'connectors': []}
    directory = _directory(status.get('connectors'))
    if routes:
        for key, (provider_name, provider) in routes.items():
            if key not in selected:
                continue
            if directory[key] is not None:
                continue
            try:
                row = _fallback_request(provider, 'status', key)
                directory[key] = dict(row, connector=key, provider=provider_name)
            except ConnectedAppError as exc:
                directory[key] = {'connector': key, 'provider': provider_name, 'connected': False,
                                  'state': 'needs_authorization', 'detail': exc.message, 'accounts': []}
    rows = _app_rows(selected, directory, identity=identity)
    if routes:
        # A local provider's actual status is independent of the Nous identity.
        for row in rows:
            source = directory.get(row['id'])
            if source and source.get('provider') in providers:
                row['detail'] = _safe_error(source.get('detail') or
                    ('Connected through your authorized account.' if source.get('connected') else
                     'Authorize this app before Pico can use it.'))
            elif row['id'] == 'twitter' and source is None:
                row['detail'] = 'X / Twitter needs your own X developer app and user-completed xurl authorization. It is not connected.'
    if action == 'status':
        return {'identity_state': 'ready' if identity else 'not_connected', 'apps': rows}
    if action == 'connect':
        needed = [directory[key]['connector'] for key in selected
                  if directory[key] and directory[key].get('provider') not in providers and directory[key].get('connected') is not True]
        if needed:
            initiated = _parse(hermes.connect(needed))
            targets = {item.get('name'): item for item in initiated.get('targets', []) if isinstance(item, dict)}
            for row in rows:
                target = targets.get(row.get('connector'))
                if not target:
                    continue
                link = _connect_url(target.get('connect_url'))
                row['connected'] = False  # only a later status proves authorization
                row['state'] = 'connecting' if link else 'disconnected'
                if link:
                    row['connect_url'] = link
                    row['detail'] = 'Finish authorization in your browser, then refresh this status.'
                elif target.get('detail'):
                    row['detail'] = _safe_error(target['detail'])
        return {'identity_state': 'ready' if identity else 'not_connected', 'apps': rows}
    if action == 'search':
        query = args.get('query')
        if not isinstance(query, str) or not 1 <= len(query.strip()) <= 2000:
            raise ConnectedAppError('invalid_argument', 'Enter a short description of the app action.')
        hosted = {directory[key]['connector'] for key in selected if directory[key] and directory[key].get('provider') not in providers}
        payload = _parse(hermes.search(query)) if hosted else {}
        schemas = payload.get('schemas') or {}
        allowed = hosted
        tools = _catalogue_search(hermes, hosted, query)
        for vendor_name, item in schemas.items():
            if len(tools) >= 30:
                break
            if not isinstance(item, dict) or item.get('connector') not in allowed:
                continue
            slug = item['connector']
            short = vendor_name.removeprefix(f'{slug.upper()}_')
            name = f'connectors__{slug}__{short}'
            if name not in tools:
                tools[name] = {'description': str(item.get('description', ''))[:2000]}
            if len(tools) >= 30:
                break
        for key in selected:
            if len(tools) >= 30:
                break
            if directory[key] and directory[key].get('provider') in providers:
                provider = providers[directory[key]['provider']]
                found = _fallback_request(provider, 'search', key, query).get('tools') or {}
                for name, metadata in found.items():
                    _, _, actual_key = _tool_name(name, directory)
                    if actual_key != key or not isinstance(metadata, dict):
                        raise ConnectedAppError('invalid_response', 'The app search returned a tool from another account provider.')
                    tools[name] = {'description': str(metadata.get('description', ''))[:2000]}
                    if len(tools) >= 30:
                        break
        return {'tools': tools}
    if action == 'describe':
        names = args.get('names')
        if not isinstance(names, list) or not 1 <= len(names) <= 10 or not all(isinstance(n, str) for n in names) or len(set(names)) != len(names):
            raise ConnectedAppError('invalid_argument', 'Describe one to ten exact app tool names.')
        for name in names:
            _tool_name(name, directory)
        return _combined_describe(hermes, fallback, names, directory, xprovider)
    name, arguments = args.get('name'), args.get('arguments')
    _, _, key = _tool_name(name, directory)
    if not isinstance(arguments, dict):
        raise ConnectedAppError('invalid_argument', 'Tool arguments must be a JSON object.')
    contract = _combined_describe(hermes, fallback, [name], directory, xprovider)['tools'][name]
    if 'expected_contract' in args and json.dumps(args['expected_contract'], sort_keys=True, ensure_ascii=False) != json.dumps(contract, sort_keys=True, ensure_ascii=False):
        raise ConnectedAppError('account_changed', 'The approved account or app operation changed. Nothing was executed.')
    schema = contract['parameters']
    helper_provider = directory[key].get('provider') in providers
    raw_schema = schema if helper_provider else hermes.raw_schema(name)
    _local_references(raw_schema)
    _local_references(schema)
    if _uses_file_inputs(raw_schema, arguments):
        raise ConnectedAppError('file_input_unsupported', 'This app action accepts file uploads; use the app directly until safe file transfer is enabled.')
    try:
        from jsonschema.validators import validator_for
    except ImportError:
        raise ConnectedAppError('dependency_missing', 'The app schema validator is missing; this action was not executed.') from None
    try:
        validator = validator_for(schema)
        validator.check_schema(schema)
    except Exception:
        raise ConnectedAppError('invalid_schema', 'The app returned an invalid argument schema; nothing was executed.') from None
    if next(validator(schema).iter_errors(arguments), None) is not None:
        raise ConnectedAppError('invalid_argument', 'Arguments do not match the current app schema; nothing was executed.')
    # The public facade uses these normalized local-file parameters; uploads are
    # explicitly refused above. No local file is silently staged by this bridge.
    if helper_provider:
        provider = providers[directory[key]['provider']]
        result = _fallback_request(provider, 'call', {'name': name, 'arguments': arguments,
                    'operation_id': args.get('operation_id'), 'expected_contract': contract})
        return dict(result, verified=False)
    result = hermes.call(name, arguments, args.get('operation_id'))
    if not isinstance(result, dict):
        raise ConnectedAppError('invalid_response', 'The app returned an invalid execute response. Check the app before retrying.', outcome_unknown=True)
    if result.get('error'):
        error = result['error']
        code = error.get('code', 'service_error') if isinstance(error, dict) else 'service_error'
        code = code if isinstance(code, str) and re.fullmatch(r'[A-Za-z0-9_]{1,80}', code) else 'service_error'
        detail = error.get('message', 'The app action failed.') if isinstance(error, dict) else error
        predispatch = {'CONNECTION_REQUIRED', 'CONNECTION_EXPIRED', 'ALIAS_REQUIRED', 'ALIAS_UNKNOWN',
                       'INVALID_ARGUMENTS', 'TOOL_NOT_FOUND', 'TOOL_NOT_ALLOWED', 'FILE_NOT_ALLOWED', 'INTERRUPTED'}
        return _error(code, _safe_error(detail), outcome_unknown=code not in predispatch)
    response = {'result': result.get('response', result), 'submitted': True, 'verified': False}
    if result.get('account'):
        response['account'] = result['account']
    return response


class ConnectedApps:
    def __init__(self, data, workspace=None, *, runner=None):
        self.data = Path(data).expanduser().resolve()
        self.workspace = Path(workspace).resolve() if workspace else None
        self.runner = runner

    def _request(self, action, args):
        try:
            if not isinstance(args, dict):
                raise ConnectedAppError('invalid_argument', 'App arguments must be a JSON object.')
            payload = json.dumps({'action': action, 'arguments': args}, ensure_ascii=False, allow_nan=False).encode()
            if len(payload) > MAX_INPUT:
                raise ConnectedAppError('request_too_large', 'The app request is too large.')
            if self.runner:
                result = self.runner(json.loads(payload), TIMEOUTS[action])
            else:
                env = {key: value for key, value in os.environ.items() if key in ENV_KEYS}
                env.update(HERMES_HOME=str(self.data / 'hermes'), HERMES_DISABLE_TELEMETRY='1',
                           DO_NOT_TRACK='1', PYTHONDONTWRITEBYTECODE='1')
                command = [sys.executable, str(Path(__file__).resolve()), '--child', '--data', str(self.data)]
                if self.workspace:
                    command += ['--workspace', str(self.workspace)]
                with tempfile.TemporaryFile() as output:
                    process = subprocess.run(command, input=payload, stdout=output, stderr=subprocess.DEVNULL,
                                             env=env, timeout=TIMEOUTS[action], check=False,
                                             cwd=str(self.workspace) if self.workspace else str(self.data.parent))
                    output.seek(0)
                    raw = output.read(MAX_OUTPUT + 1)
                if len(raw) > MAX_OUTPUT:
                    raise ConnectedAppError('response_too_large', 'The app response is too large. Narrow the request.', outcome_unknown=action == 'call')
                if process.returncode:
                    raise ConnectedAppError('bridge_failed', 'The app connection could not complete.', outcome_unknown=action == 'call')
                result = json.loads(raw)
            if not isinstance(result, dict) or len(json.dumps(result).encode()) > MAX_OUTPUT:
                raise ConnectedAppError('invalid_response', 'The app bridge returned an invalid response.', outcome_unknown=action == 'call')
            return result
        except subprocess.TimeoutExpired:
            return _error('timeout', 'The app did not answer in time. Check the app before retrying a change.', outcome_unknown=action == 'call')
        except ConnectedAppError as exc:
            return _error(exc.code, exc.message, outcome_unknown=exc.outcome_unknown)
        except (OSError, ValueError, TypeError, KeyError):
            return _error('bridge_failed', 'The app connection could not complete.', outcome_unknown=action == 'call')

    def status(self, args=None): return self._request('status', {} if args is None else args)
    def connect(self, args): return self._request('connect', args)
    def search(self, args): return self._request('search', args)
    def describe(self, args): return self._request('describe', args)
    def call(self, args): return self._request('call', args)


def main(argv=None):
    parser = argparse.ArgumentParser(description='Pico connected app status and authorization.')
    parser.add_argument('--data', default=str(Path.home() / 'Library/Application Support/Telos'))
    parser.add_argument('--child', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--workspace', help=argparse.SUPPRESS)
    options = parser.parse_args(argv)
    output = sys.stdout
    logging.disable(logging.CRITICAL)
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(raw) > MAX_INPUT:
            raise ConnectedAppError('request_too_large', 'The app request is too large.')
        request = json.loads(raw)
        if not isinstance(request, dict):
            raise ConnectedAppError('invalid_argument', 'App request must be a JSON object.')
        action = request.get('action', 'status')
        args = request.get('arguments', request)
        if not options.child:
            if action not in ('status', 'connect'):
                raise ConnectedAppError('invalid_argument', 'Only status and connect are available through this Settings command.')
            result = ConnectedApps(options.data)._request(action, args)
        else:
            # No dependency print/progress output may enter the NDJSON/UI wire.
            with open(os.devnull, 'w') as quiet, contextlib.redirect_stdout(quiet), contextlib.redirect_stderr(quiet):
                result = _dispatch(action, args, data=options.data, workspace=options.workspace)
        encoded = json.dumps(result, ensure_ascii=False, allow_nan=False)
        if len(encoded.encode()) > MAX_OUTPUT:
            raise ConnectedAppError('response_too_large', 'The app response is too large. Narrow the request.', outcome_unknown=action == 'call')
    except ConnectedAppError as exc:
        encoded = json.dumps(_error(exc.code, exc.message, outcome_unknown=exc.outcome_unknown))
    except Exception:
        encoded = json.dumps(_error('service_error', 'The app service could not complete this request.', outcome_unknown=locals().get('action') == 'call'))
    output.write(encoded + '\n')
    output.flush()


if __name__ == '__main__':
    main()
