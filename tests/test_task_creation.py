import sys
import unittest
import threading
import datetime as dt
import re
import json
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from task_creation import register_task_creation

class TaskCreationTests(unittest.TestCase):
    def setup_tool(self, confirmed=True, source_text=None, clock=None):
        events = []
        class Gate:
            lock = threading.Lock()
            def reader(self, timeout):
                return {'request_id': events[-1][1]['request_id'], 'status': 'saved_not_started'} if confirmed else None
        handlers = {}
        register_task_creation(lambda name, desc, props, required, handler: handlers.update({name: handler}), lambda kind, **args: events.append((kind, args)), Gate(), source_text=source_text, clock=clock)
        return handlers['create_tasks'], events
    def test_acknowledgement(self):
        tool, events = self.setup_tool()
        self.assertEqual(tool({'tasks': [{'title': 'Test', 'instructions': 'Do this'}]})['status'], 'saved_not_started')
        self.assertEqual(events[0][0], 'create_tasks')
    def test_no_ack_no_success(self):
        tool, _ = self.setup_tool(False)
        self.assertIn('error', tool({'tasks': [{'title': 'Test', 'instructions': 'Do this'}]}))
    def test_invalid_no_event(self):
        tool, events = self.setup_tool()
        for tasks in ([], [{}], [{'title': 'A', 'instructions': 'B'}] * 6):
            with self.assertRaises(ValueError): tool({'tasks': tasks})
        self.assertFalse(events)

    def test_current_local_date_and_deadline_evidence_contract(self):
        now = dt.datetime(2026, 10, 25, 0, 30, tzinfo=dt.timezone(dt.timedelta(hours=8)))
        source = '给我建三件待办：周四前整理 Allhands；下周做排期；在 October 30, 2026 发评审稿。'
        tool, events = self.setup_tool(source_text=lambda _: source, clock=lambda: now)
        proposals = [
            {'title': '整理 Allhands', 'instructions': '周四前整理 Allhands', 'due_date': '2026-10-29', 'due_date_evidence': '周四前'},
            {'title': '做排期', 'instructions': '下周做排期'},
            {'title': '评审稿', 'instructions': '准备评审稿', 'due_date': '2026-10-30', 'due_date_evidence': 'October 30, 2026'}]
        tool({'tasks': proposals})
        rows = events[0][1]['tasks']
        self.assertEqual([row.get('due_date') for row in rows], ['2026-10-29', None, '2026-10-30'])
        self.assertTrue(all('due_date_evidence' not in row for row in rows), 'Evidence validates the protocol; only the normalized date is persisted')
        self.assertEqual(proposals[0]['due_date_evidence'], '周四前', 'Do not mutate the agent payload')

    def test_relative_weekdays_use_local_current_week_and_keep_qualifiers(self):
        now = dt.datetime(2026, 10, 26, 9, tzinfo=dt.timezone(dt.timedelta(hours=8)))
        for phrase, date in [('周四前', '2026-10-29'), ('下周四', '2026-11-05'), ('本周四', '2026-10-29'), ('明天', '2026-10-27')]:
            with self.subTest(phrase=phrase):
                tool, events = self.setup_tool(source_text=lambda _, value=phrase: '请建任务，' + value + '做完', clock=lambda: now)
                tool({'tasks': [{'title': 'Task', 'instructions': 'Exact task', 'due_date': date, 'due_date_evidence': phrase}]})
                self.assertEqual(events[0][1]['tasks'][0]['due_date'], date)

    def test_no_date_is_added_to_an_undated_request(self):
        tool, events = self.setup_tool(source_text=lambda _: '请帮我建个修改文案的待办')
        tool({'tasks': [{'title': '修改文案', 'instructions': '保留没有截止日期的待办'}]})
        self.assertNotIn('due_date', events[0][1]['tasks'][0])

    def test_dates_must_be_real_and_match_current_user_evidence(self):
        now = dt.datetime(2026, 10, 25, tzinfo=dt.timezone(dt.timedelta(hours=8)))
        tool, events = self.setup_tool(source_text=lambda _: '周四前做完；下周安排排期', clock=lambda: now)
        bad = [
            {'due_date': '2026-02-30', 'due_date_evidence': '周四前'},
            {'due_date': '2026-10-28', 'due_date_evidence': '周四前'},
            {'due_date': '2026-10-29', 'due_date_evidence': '2026-10-29'},
            {'due_date': '2026-11-01', 'due_date_evidence': '下周'},
            {'due_date': '2026-10-29'},
            {'due_date': 20261029, 'due_date_evidence': '周四前'}]
        for fields in bad:
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                tool({'tasks': [{'title': 'Task', 'instructions': 'Exact task', **fields}]})
        self.assertFalse(events, 'Reject the whole batch before native task persistence')

    def test_cannot_drop_weekday_qualifiers_from_original_quote(self):
        now = dt.datetime(2026, 10, 26, 9, tzinfo=dt.timezone(dt.timedelta(hours=8)))
        for source, quote in [('下周四前完成', '周四前'), ('下个星期四完成', '星期四'), ('本周四完成', '周四'), ('这周四完成', '周四'), ('下下周四完成', '下周四')]:
            with self.subTest(source=source):
                tool, events = self.setup_tool(source_text=lambda _, value=source: value, clock=lambda: now)
                with self.assertRaises(ValueError):
                    tool({'tasks': [{'title': 'Task', 'instructions': 'Do not shift the deadline',
                                     'due_date': '2026-10-29', 'due_date_evidence': quote}]})
                self.assertFalse(events)

    def test_attachment_names_and_manifest_are_not_user_deadline_evidence(self):
        source = '[Attachment: 2026-10-29.txt]请建一个研究任务'
        source += '\n\nUser attached files, in order of inline attachment markers (paths relative to conversation workspace): '
        source += json.dumps([{'name': '2026-10-29.txt', 'path': 'attachments/2026-10-29.txt'}])
        source += '\nRead relevant attachments before answering.'
        tool, events = self.setup_tool(source_text=lambda _: source)
        with self.assertRaises(ValueError):
            tool({'tasks': [{'title': 'Research', 'instructions': 'No requested deadline',
                             'due_date': '2026-10-29', 'due_date_evidence': '2026-10-29'}]})
        self.assertFalse(events)

    def test_schema_has_local_clock_and_keeps_due_date_optional(self):
        captured = {}
        now = dt.datetime(2026, 10, 25, 0, 30, tzinfo=dt.timezone(dt.timedelta(hours=8)))
        register_task_creation(lambda name, desc, props, required, handler: captured.update(description=desc, properties=props), None, None, clock=lambda: now)
        schema = captured['properties']['tasks']['items']
        self.assertEqual(schema['required'], ['title', 'instructions'])
        self.assertIn('2026-10-25', captured['description'])
        self.assertIn('UTC+0800', captured['description'])
        self.assertIn('get_current_time', captured['description'])
        self.assertIn('due_date_evidence', schema['properties'])
        self.assertIsNotNone(re.fullmatch(schema['properties']['due_date']['pattern'], '2026-10-29'))
        self.assertIsNone(re.fullmatch(schema['properties']['due_date']['pattern'], '2026-2-3'))
