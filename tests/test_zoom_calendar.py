import datetime as dt
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from zoom_connector import ZoomConnector, ZoomError
from zoom_calendar import ZoomCalendarSync, chosen_calendars, normalized_event, timestamp, unwrap


SCHEMAS = {
    'calendar_get_inuse': {'type': 'object', 'properties': {}, 'additionalProperties': False},
    'calendar_list': {'type': 'object', 'properties': {
        'service': {'enum': ['zoom', 'inUse']}, 'maxResults': {'type': 'integer'},
        'showHidden': {'type': 'boolean'}, 'showDeleted': {'type': 'boolean'}, 'pageToken': {'type': 'string'}}, 'additionalProperties': False},
    'calendar_list_events': {'type': 'object', 'required': ['cal_id'], 'properties': {
        'service': {'enum': ['zoom', 'inUse']}, 'cal_id': {'type': 'string'},
        'timeMin': {'type': 'string'}, 'timeMax': {'type': 'string'}, 'timeZone': {'type': 'string'},
        'singleEvents': {'type': 'boolean'}, 'orderBy': {'enum': ['startTime', 'updated']},
        'showDeleted': {'type': 'boolean'}, 'maxResults': {'type': 'integer'}, 'pageToken': {'type': 'string'}}, 'additionalProperties': False},
}


def event(identity='event', day=22, **extra):
    value = {'id': identity, 'iCalUID': identity + '-uid', 'summary': 'Synthetic event', 'status': 'confirmed',
             'start': {'dateTime': f'2026-10-{day:02}T09:00:00+08:00', 'timeZone': 'Asia/Shanghai'},
             'end': {'dateTime': f'2026-10-{day:02}T10:00:00+08:00', 'timeZone': 'Asia/Shanghai'}}
    value.update(extra)
    return value


class Helper:
    def __init__(self):
        self.calls = []
        self.binding = {'items': [{'type': 'zoom', 'email': 'owner@example.test', 'inUse': True, 'isPrimary': True}]}
        self.calendars = {'items': [{'id': 'primary', 'accessRole': 'owner', 'selected': True, 'primary': True, 'hidden': False}]}
        self.event_pages = {'primary': {'items': [event()]}}
        self.on_call = None

    def __call__(self, command):
        args = command[2:-1]
        self.calls.append(args)
        if args == ['calendar']:
            return 'Zoom Calendar — tools:\n' + '\n'.join('  ' + name + '  Read data' for name in SCHEMAS)
        if len(args) == 3 and args[1] == 'schema':
            return 'Input Schema:\n' + json.dumps(SCHEMAS[args[2]])
        tool = args[1]
        params = json.loads(args[-1])
        if self.on_call:
            self.on_call(tool, params)
        if tool == 'calendar_get_inuse':
            value = self.binding
        elif tool == 'calendar_list':
            value = self.calendars
            if isinstance(value, dict) and 'pages' in value:
                value = value['pages'][params.get('pageToken', '')]
        else:
            value = self.event_pages[params['cal_id']]
            if isinstance(value, dict) and 'pages' in value:
                value = value['pages'][params.get('pageToken', '')]
        if isinstance(value, Exception):
            raise value
        return json.dumps(value)


class ZoomCalendarTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.data = Path(self.temp.name)
        self.settings = self.data / 'zoom-connection.json'
        self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'synthetic-connection'}))
        self.helper = Helper()
        self.connector = ZoomConnector(self.data, runner=self.helper, helper='/usr/bin/true')
        self.syncer = ZoomCalendarSync(self.connector)
        self.bounds = ['2026-10-22T00:00:00+08:00', '2026-10-29T00:00:00+08:00', 'Asia/Shanghai']

    def tearDown(self):
        self.temp.cleanup()

    def sync(self):
        return self.syncer.sync(*self.bounds)

    def test_direct_read_selected_calendar_schema_and_no_mutation(self):
        self.helper.calendars['items'].extend([
            {'id': 'unselected-shared', 'accessRole': 'reader'},
            {'id': 'hidden', 'accessRole': 'reader', 'selected': True, 'hidden': True},
            {'id': 'freebusy', 'accessRole': 'freeBusyReader', 'selected': True}])
        result = self.sync()
        self.assertTrue(result['complete'])
        self.assertEqual(result['state'], 'connected')
        self.assertEqual(len(result['events']), 1)
        self.assertEqual(result['calendars_synced'], 1)
        self.assertEqual(result['connection_id'], 'synthetic-connection')
        self.assertEqual(len(result['account_id']), 64)
        self.assertNotIn('owner@', json.dumps(result))
        reads = [args for args in self.helper.calls if '--args-json' in args]
        self.assertEqual([row[1] for row in reads], ['calendar_get_inuse', 'calendar_list', 'calendar_list_events', 'calendar_get_inuse'])
        args = json.loads(reads[-2][-1])
        self.assertTrue(args['singleEvents'])
        self.assertEqual(args['service'], 'inUse')
        self.assertEqual(args['timeZone'], 'Asia/Shanghai')
        self.assertEqual(args['orderBy'], 'startTime')
        for name in SCHEMAS:
            self.assertLess(self.helper.calls.index(['calendar', 'schema', name]),
                            next(i for i, call in enumerate(self.helper.calls) if len(call) > 3 and call[1] == name))

    def test_calendar_and_event_pagination_complete_no_duplicate_instances(self):
        self.helper.calendars = {'pages': {
            '': {'items': [{'id': 'primary', 'primary': True, 'accessRole': 'owner'}], 'nextPageToken': 'cal-next'},
            'cal-next': {'items': [{'id': 'shared', 'selected': True, 'accessRole': 'reader'}]}}}
        first = event('repeat', recurrenceId='2026-10-22T01:00:00Z', recurringEventId='master')
        second = event('repeat', day=23, recurrenceId='2026-10-23T01:00:00Z', recurringEventId='master')
        # Identical UID + instant may be returned again by another selected calendar.
        duplicate = dict(first, id='provider-copy')
        duplicate['start'] = {'dateTime': '2026-10-22T01:00:00Z'}
        duplicate['end'] = {'dateTime': '2026-10-22T02:00:00Z'}
        self.helper.event_pages = {
            'primary': {'pages': {'': {'items': [first], 'nextPageToken': 'event-next'}, 'event-next': {'items': [second]}}},
            'shared': {'items': [duplicate]}}
        result = self.sync()
        self.assertEqual(len(result['events']), 2)
        self.assertEqual(result['calendars_synced'], 2)
        self.assertEqual(result['pages_read'], 5)
        self.assertNotEqual(result['events'][0]['id'], result['events'][1]['id'])

    def test_cancelled_declined_and_overlap_filtering(self):
        self.helper.event_pages['primary'] = {'items': [
            event('keep'), event('cancel', status='cancelled', start=None),
            event('decline', attendees=[{'email': 'OWNER@EXAMPLE.TEST', 'responseStatus': 'declined'}]),
            event('self-decline', attendees=[{'self': True, 'responseStatus': 'declined'}]),
            event('other-decline', attendees=[{'email': 'other@example.test', 'responseStatus': 'declined'}]),
            event('response-decline', responseStatus={'response': 'declined'}),
            event('outside', day=29),
            event('multi-day', start={'date': '2026-10-20'}, end={'date': '2026-10-24'})]}
        rows = self.sync()['events']
        self.assertEqual(len(rows), 3)
        self.assertEqual(sum(row['allDay'] for row in rows), 1)

    def test_exclusive_all_day_end_dst_and_naive_provider_timezone(self):
        begin, all_day = timestamp({'date': '2026-03-08'}, 'America/Los_Angeles')
        end, _ = timestamp({'date': '2026-03-09'}, 'America/Los_Angeles')
        self.assertTrue(all_day)
        self.assertEqual((end.timestamp() - begin.timestamp()) / 3600, 23)
        naive, _ = timestamp({'dateTime': '2026-03-08T09:00:00', 'timeZone': 'Pacific Standard Time'}, 'UTC')
        self.assertEqual(naive.utcoffset(), dt.timedelta(hours=-7))
        self.helper.event_pages['primary'] = {'items': [
            event('exclusive', start={'date': '2026-10-20'}, end={'date': '2026-10-22'}),
            event('span', start={'date': '2026-10-21'}, end={'date': '2026-10-24'})]}
        self.assertEqual(len(self.sync()['events']), 1)

    def test_partial_page_failure_never_becomes_success_or_partial_snapshot(self):
        self.helper.event_pages['primary'] = {'pages': {
            '': {'items': [event()], 'nextPageToken': 'next'},
            'next': ZoomError('permission_denied', 'Synthetic permission failure')}}
        with self.assertRaises(ZoomError) as caught:
            self.sync()
        failure = self.syncer.failure(caught.exception)
        self.assertFalse(failure['complete'])
        self.assertEqual(failure['events'], [])
        self.assertEqual(failure['state'], 'permission_denied')
        self.assertEqual(len(failure['account_id']), 64)

    def test_auth_disconnected_and_account_switch_do_not_mix_snapshots(self):
        self.settings.write_text(json.dumps({'enabled': False, 'connection_id': 'synthetic-connection'}))
        with self.assertRaises(ZoomError) as caught:
            self.sync()
        self.assertEqual(caught.exception.state, 'disconnected')
        self.assertFalse(self.helper.calls)
        self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'synthetic-connection'}))
        def change(tool, _):
            if tool == 'calendar_list_events':
                self.settings.write_text(json.dumps({'enabled': True, 'connection_id': 'changed'}))
        self.helper.on_call = change
        with self.assertRaises(ZoomError) as caught:
            self.sync()
        self.assertEqual(caught.exception.state, 'disconnected')

    def test_error_wrappers_malformed_lists_and_repeated_tokens_fail_closed(self):
        for value in ({'content': [{'type': 'text', 'text': '{"error":"401 expired token"}'}]},
                      {'items': None}, {'value': [], '@odata.nextLink': 'unsupported'}):
            self.helper.calendars = value
            with self.assertRaises(ZoomError):
                self.sync()
        self.helper.calendars = {'items': [{'id': 'primary', 'primary': True}], 'nextPageToken': 'same'}
        with self.assertRaisesRegex(ZoomError, 'repeated'):
            self.sync()

    def test_large_result_reassembles_connector_cached_chunks_without_refetch(self):
        self.helper.event_pages['primary'] = {'items': [event('large', description='Synthetic ' * 6000)]}
        self.assertEqual(len(self.sync()['events']), 1)
        event_reads = [call for call in self.helper.calls if len(call) > 3 and call[1] == 'calendar_list_events']
        self.assertEqual(len(event_reads), 1)
        self.assertGreater(len(json.dumps(self.helper.event_pages['primary'])), self.connector.RESULT_LIMIT)

    def test_deadline_invalid_dates_and_unknown_response_are_not_empty_success(self):
        self.syncer.deadline = self.syncer.clock() - 1
        with self.assertRaises(ZoomError) as caught:
            self.sync()
        self.assertEqual(caught.exception.state, 'timeout')
        self.syncer.deadline = self.syncer.clock() + 75
        self.helper.event_pages['primary'] = {'items': [event(start={'dateTime': 'broken'})]}
        with self.assertRaisesRegex(ZoomError, 'invalid dates'):
            self.sync()
        self.helper.event_pages['primary'] = {'unexpected': []}
        with self.assertRaises(ZoomError):
            self.sync()

    def test_unexpanded_recurring_master_and_unknown_account_fail_closed(self):
        self.helper.event_pages['primary'] = {'items': [event(recurrence=['RRULE:FREQ=DAILY'])]}
        with self.assertRaisesRegex(ZoomError, 'expand'):
            self.sync()
        self.helper.binding['items'][0].pop('email')
        with self.assertRaisesRegex(ZoomError, 'identify'):
            self.sync()

    def test_devhelper_account_changes_during_fetch_cannot_publish_mixed_snapshot(self):
        before = self.sync()['account_id']
        self.syncer = ZoomCalendarSync(self.connector)
        def switch_account(tool, _):
            if tool == 'calendar_list_events':
                self.helper.binding['items'][0]['email'] = 'new-account@example.test'
        self.helper.on_call = switch_account
        with self.assertRaises(ZoomError) as caught:
            self.sync()
        result = self.syncer.failure(caught.exception)
        self.assertEqual(result['state'], 'connection_changed')
        self.assertEqual(result['events'], [])
        self.assertNotEqual(result['account_id'], before)

    def test_selection_fallback_when_provider_has_no_flags_and_identity_is_opaque(self):
        rows = chosen_calendars([{'id': 'one', 'accessRole': 'owner'}, {'id': 'two', 'accessRole': 'reader'},
                                 {'id': 'three', 'accessRole': 'freeBusyReader'}, {'id': 'four', 'hidden': True}])
        self.assertEqual([row['id'] for row in rows], ['one', 'two'])
        first = self.sync()['account_id']
        self.helper.binding['items'][0]['email'] = 'different@example.test'
        self.syncer = ZoomCalendarSync(self.connector)
        self.assertNotEqual(first, self.sync()['account_id'])
        payload = unwrap({'content': [{'type': 'text', 'text': '{"items":[]}'}]})
        self.assertEqual(payload, {'items': []})


if __name__ == '__main__':
    unittest.main()
