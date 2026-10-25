"""Direct, read-only Zoom Calendar synchronization for Pico's Events tab.

The existing connector owns authentication, schema checks and the read allowlist.
This module returns a complete bounded snapshot or a failure, never a partial
snapshot disguised as an empty calendar. No event content is written to disk.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import signal
import sys
import time
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from zoom_connector import ZoomConnector, ZoomError, _result_error, _failure


UTC = dt.timezone.utc
MAX_PAGES = 100
MAX_EVENTS = 20000
# The gateway accepts an IANA query zone; a routed Microsoft response may still
# label a naive datetime with its Windows zone name.
WINDOWS_ZONES = {
    'UTC': 'UTC', 'Pacific Standard Time': 'America/Los_Angeles',
    'Mountain Standard Time': 'America/Denver', 'US Mountain Standard Time': 'America/Phoenix',
    'Central Standard Time': 'America/Chicago', 'Eastern Standard Time': 'America/New_York',
    'GMT Standard Time': 'Europe/London', 'W. Europe Standard Time': 'Europe/Berlin',
    'China Standard Time': 'Asia/Shanghai', 'Singapore Standard Time': 'Asia/Singapore',
    'Tokyo Standard Time': 'Asia/Tokyo', 'India Standard Time': 'Asia/Kolkata',
    'AUS Eastern Standard Time': 'Australia/Sydney',
}


def zone(name):
    try:
        return ZoneInfo(WINDOWS_ZONES.get(name, name))
    except (ZoneInfoNotFoundError, TypeError, ValueError):
        raise ZoomError('invalid_response', 'Zoom returned an unsupported calendar timezone. The previous complete sync was kept.') from None


def timestamp(value, fallback_zone):
    """Return (aware datetime, is_date) without shifting date-only events to UTC."""
    if isinstance(value, dict):
        timezone = value.get('timeZone') or value.get('timezone') or fallback_zone
        if value.get('date'):
            return dt.datetime.combine(dt.date.fromisoformat(value['date']), dt.time(), zone(timezone)), True
        value = value.get('dateTime', value.get('datetime'))
    else:
        timezone = fallback_zone
    if not isinstance(value, str):
        raise ValueError('Missing event time')
    if len(value) == 10:
        return dt.datetime.combine(dt.date.fromisoformat(value), dt.time(), zone(timezone)), True
    parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=zone(timezone))
    return parsed, False


def unwrap(value):
    """Decode only known transport envelopes, not arbitrary event descriptions."""
    for _ in range(10):
        if _result_error(value):
            raise _failure(json.dumps(value, ensure_ascii=False))
        if isinstance(value, str):
            try:
                value = json.loads(value)
            except ValueError:
                raise ZoomError('invalid_response', 'Zoom returned an unreadable calendar response. No calendar snapshot was replaced.') from None
        elif isinstance(value, dict) and isinstance(value.get('content'), list):
            parts = [item.get('text') for item in value['content']
                     if isinstance(item, dict) and item.get('type') == 'text' and isinstance(item.get('text'), str)]
            if len(parts) != 1:
                raise ZoomError('invalid_response', 'Zoom returned an unsupported calendar response. No calendar snapshot was replaced.')
            value = parts[0]
        elif isinstance(value, dict) and not any(key in value for key in ('items', 'events', 'value', 'calendars')):
            wrapped = next((key for key in ('data', 'result', 'body') if isinstance(value.get(key), (dict, list, str))), None)
            if wrapped is None:
                return value
            value = value[wrapped]
        else:
            return value
    raise ZoomError('invalid_response', 'Zoom returned too many nested calendar response envelopes.')


def page(value, kind):
    value = unwrap(value)
    if isinstance(value, list):
        return value, None
    if not isinstance(value, dict):
        raise ZoomError('invalid_response', 'Zoom did not return a calendar list. No calendar snapshot was replaced.')
    keys = ('items', 'calendars', 'value') if kind == 'calendars' else ('items', 'events', 'value')
    rows = next((value[key] for key in keys if key in value), None)
    if not isinstance(rows, list) or any(not isinstance(item, dict) for item in rows):
        raise ZoomError('invalid_response', 'Zoom did not return a complete calendar list. No calendar snapshot was replaced.')
    token = next((value[key] for key in ('nextPageToken', 'next_page_token') if value.get(key)), None)
    if token is not None and not isinstance(token, str):
        raise ZoomError('invalid_response', 'Zoom returned an invalid calendar page token.')
    # Do not claim complete coverage for an unhandled provider pagination form.
    if any(value.get(key) for key in ('@odata.nextLink', 'nextLink', 'hasMore', 'has_more')) and not token:
        raise ZoomError('invalid_response', 'Zoom returned an unsupported calendar pagination format. No calendar snapshot was replaced.')
    return rows, token


def chosen_calendars(values):
    # Google/Zoom omit selected for unselected calendars. If selection metadata
    # exists anywhere, do not accidentally import every shared coworker calendar.
    has_selection = any('selected' in item or 'primary' in item for item in values)
    chosen, seen = [], set()
    for item in values:
        if item.get('hidden') is True or item.get('deleted') is True:
            continue
        if item.get('accessRole') in ('none', 'freeBusyReader'):
            continue
        if has_selection and not (item.get('selected') is True or item.get('primary') is True):
            continue
        if not has_selection and item.get('selected') is False:
            continue
        identity = item.get('id')
        if not isinstance(identity, str) or not identity:
            raise ZoomError('invalid_response', 'Zoom returned a calendar without an identifier.')
        if identity not in seen:
            seen.add(identity)
            chosen.append(item)
    return chosen


def normalized_event(item, calendar_id, timezone, current_email, start, end):
    if str(item.get('status', '')).lower() in ('canceled', 'cancelled', 'deleted') or item.get('isCancelled') is True or item.get('deleted') is True:
        return None
    own_response = item.get('responseStatus')
    if isinstance(own_response, dict) and str(own_response.get('response', '')).lower() == 'declined':
        return None
    for person in item.get('attendees', []) or []:
        if not isinstance(person, dict):
            continue
        own = person.get('self') is True or person.get('isCurrentUser') is True
        if current_email and str(person.get('email', '')).casefold() == current_email.casefold():
            own = True
        if own and str(person.get('responseStatus', person.get('status', ''))).lower() == 'declined':
            return None
    if item.get('recurrence') and not (item.get('recurringEventId') or item.get('recurrenceId') or item.get('originalStartTime')):
        raise ZoomError('invalid_response', 'Zoom did not expand a recurring event into instances. The previous complete sync was kept.')
    try:
        begin, date_start = timestamp(item.get('start'), timezone)
        finish, date_end = timestamp(item.get('end'), timezone)
    except (ValueError, TypeError, OverflowError):
        raise ZoomError('invalid_response', 'Zoom returned an event with invalid dates. The previous complete sync was kept.') from None
    if finish <= begin:
        raise ZoomError('invalid_response', 'Zoom returned an event with an invalid duration. The previous complete sync was kept.')
    if begin >= end or finish <= start:
        return None
    title = item.get('summary', item.get('subject', item.get('title', '')))
    if not isinstance(title, str):
        title = ''
    title = title.strip() or 'Untitled event'
    uid = item.get('iCalUID', item.get('iCalUId'))
    source_id = item.get('id')
    if isinstance(uid, str) and uid:
        identity = [uid, begin.timestamp()]
    elif isinstance(source_id, str) and source_id:
        identity = [calendar_id, source_id]
    else:
        raise ZoomError('invalid_response', 'Zoom returned an event without an identifier. No calendar snapshot was replaced.')
    opaque_id = hashlib.sha256(json.dumps(identity, ensure_ascii=False).encode()).hexdigest()
    return {'id': 'zoom:' + opaque_id, 'title': title, 'start': begin.timestamp(),
            'end': finish.timestamp(), 'allDay': (date_start and date_end) or item.get('isAllDay') is True}


class ZoomCalendarSync:
    def __init__(self, connector, *, timeout=75, clock=time.monotonic):
        self.connector = connector
        self.clock = clock
        self.deadline = clock() + timeout
        self.connection_id = connector._settings().get('connection_id')
        self.account_id = None
        self.current_email = ''
        self.calendars_read = 0
        self.pages_read = 0

    def checked(self):
        self.connector._require_enabled()
        if self.connector._settings().get('connection_id') != self.connection_id:
            raise ZoomError('disconnected', 'The Zoom connection changed during sync. Reopen Events to sync the current connection.')
        remaining = self.deadline - self.clock()
        if remaining <= 0:
            raise ZoomError('timeout', 'Zoom calendar sync timed out. The previous complete sync was kept.')
        # This instance is owned by a single sync; clamp each helper process to
        # the remaining total budget, including schema discovery commands.
        self.connector.COMMAND_TIMEOUT = min(25, remaining)

    def read(self, tool, arguments):
        self.checked()
        # Discovering a new service/tool may issue both a catalog and a schema
        # request. Reserve the remaining total budget across those two commands,
        # then reclamp before the actual read (whose schema is now cached).
        self.connector.COMMAND_TIMEOUT = min(25, max(0.01, (self.deadline - self.clock()) / 2))
        self.connector.schema({'service': 'calendar', 'tool': tool})
        self.checked()
        request = {'service': 'calendar', 'tool': tool, 'arguments': arguments}
        result = self.connector.read(request)
        if result.get('truncated'):
            chunks = [result['content_excerpt']]
            offset = result.get('next_output_offset')
            while offset is not None:
                self.checked()
                previous = offset
                result = self.connector.read(dict(request, output_offset=offset))
                chunks.append(result['content_excerpt'])
                offset = result.get('next_output_offset')
                if offset is not None and offset <= previous:
                    raise ZoomError('invalid_response', 'Zoom calendar response paging did not advance.')
            try:
                result = {'result': json.loads(''.join(chunks))}
            except ValueError:
                raise ZoomError('invalid_response', 'Zoom returned an incomplete calendar response.') from None
        self.checked()
        return unwrap(result.get('result'))

    def pages(self, tool, arguments, kind):
        token, seen, rows = None, set(), []
        for _ in range(MAX_PAGES):
            self.checked()
            args = dict(arguments)
            if token:
                args['pageToken'] = token
            values, next_token = page(self.read(tool, args), kind)
            self.pages_read += 1
            rows.extend(values)
            if len(rows) > MAX_EVENTS:
                raise ZoomError('invalid_response', 'Zoom returned too many events for one sync. The previous complete sync was kept.')
            if not next_token:
                return rows
            if next_token in seen:
                raise ZoomError('invalid_response', 'Zoom repeated a calendar page token. No calendar snapshot was replaced.')
            seen.add(next_token)
            token = next_token
        raise ZoomError('invalid_response', 'Zoom calendar pagination exceeded the sync limit. The previous complete sync was kept.')

    def sync(self, start, end, timezone):
        start, _ = timestamp(start, timezone)
        end, _ = timestamp(end, timezone)
        if start >= end or end - start > dt.timedelta(days=8):
            raise ZoomError('invalid_argument', 'Use a bounded upcoming calendar range of at most eight days.')
        zone(timezone)
        self.checked()
        binding, self.account_id = self.active_binding()
        self.current_email = binding['email']
        calendars = chosen_calendars(self.pages('calendar_list', {'service': 'inUse', 'maxResults': 100,
                                                               'showHidden': False, 'showDeleted': False}, 'calendars'))
        entries = {}
        for calendar in calendars:
            items = self.pages('calendar_list_events', {'service': 'inUse', 'cal_id': calendar['id'],
                    'timeMin': start.isoformat(), 'timeMax': end.isoformat(), 'timeZone': timezone,
                    'singleEvents': True, 'orderBy': 'startTime', 'showDeleted': False,
                    'maxResults': 250}, 'events')
            self.calendars_read += 1
            for item in items:
                entry = normalized_event(item, calendar['id'], timezone, self.current_email, start, end)
                if entry is not None:
                    entries[entry['id']] = entry
        # DevHelper's signed-in account can change without changing Pico's local
        # access switch. Verify routing again before publishing the whole batch.
        try:
            _, current_account_id = self.active_binding()
        except ZoomError:
            # The final identity could not be confirmed. Do not let an old
            # fingerprint authorize display of a cache for a possibly new user.
            self.account_id = None
            raise
        if current_account_id != self.account_id:
            self.account_id = current_account_id
            raise ZoomError('connection_changed', 'The Zoom calendar account changed during sync. Open Events again to sync the current account.')
        self.checked()
        return {'source': 'zoom', 'state': 'connected', 'message': 'Synced directly from Zoom Calendar.',
                'events': sorted(entries.values(), key=lambda item: (item['start'], item['id'])),
                'complete': True, 'connection_id': self.connection_id, 'account_id': self.account_id,
                'calendars_synced': self.calendars_read, 'pages_read': self.pages_read,
                'fetched_at': dt.datetime.now(UTC).timestamp()}

    def active_binding(self):
        routing = self.read('calendar_get_inuse', {})
        bindings = routing.get('items') if isinstance(routing, dict) else routing
        if not isinstance(bindings, list):
            raise ZoomError('invalid_response', 'Zoom did not return its active calendar binding.')
        binding = next((item for item in bindings if isinstance(item, dict) and item.get('inUse') is True), None)
        if binding is None:
            raise ZoomError('disconnected', 'No active calendar is connected in Zoom. Connect a calendar in Zoom Workplace first.')
        email = binding.get('email', '')
        if not isinstance(email, str) or not email.strip():
            raise ZoomError('invalid_response', 'Zoom did not identify the active calendar account. No calendar snapshot was replaced.')
        identity = {key: binding.get(key) for key in ('type', 'email', 'serviceId')}
        identity['email'] = str(identity.get('email') or '').strip().casefold()
        return binding, hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()

    def failure(self, error):
        return {'source': 'zoom', 'state': error.state, 'message': str(error), 'events': [], 'complete': False,
                'connection_id': self.connector._settings().get('connection_id'), 'account_id': self.account_id}


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    parser = argparse.ArgumentParser()
    parser.add_argument('--start', required=True)
    parser.add_argument('--end', required=True)
    parser.add_argument('--timezone', required=True)
    args = parser.parse_args()
    data = Path(os.environ.get('TELOS_DATA_DIR', str(Path.home() / 'Library/Application Support/Telos')))
    sync = ZoomCalendarSync(ZoomConnector(data))
    try:
        result = sync.sync(args.start, args.end, args.timezone)
    except ZoomError as error:
        result = sync.failure(error)
    except Exception:
        result = sync.failure(ZoomError('unavailable', 'Pico could not sync Zoom Calendar. The previous complete sync was kept. Try again later.'))
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
