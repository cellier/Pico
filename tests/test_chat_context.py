import json
import sqlite3
import sys
import tempfile
import unittest
import uuid
from contextlib import closing
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from chat_context import ChatContext


class ChatContextTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.context = ChatContext(self.temp.name, max_chars=8000, recent_turns=4)

    def turn(self, prompt, answer, *, prefix=None, result_messages=None, completed=True):
        run, message = str(uuid.uuid4()), str(uuid.uuid4())
        self.context.begin(run, message, prompt)
        messages = result_messages or [{'role': 'user', 'content': prompt}, {'role': 'assistant', 'content': answer}]
        prefix = prefix or []
        self.context.finish({'messages': prefix + messages, 'current_turn_user_idx': len(prefix),
                             'final_response': answer, 'completed': completed})
        return run

    def next_turn(self):
        self.context.begin(str(uuid.uuid4()), str(uuid.uuid4()), 'Continue')

    def test_archive_is_durable_and_only_new_turn_is_archived(self):
        prefix = [{'role': 'user', 'content': 'Do not duplicate this old turn'}]
        run = self.turn('Remember the project color', 'Indigo', prefix=prefix)
        self.context.record('done', {'text': 'Indigo'})
        reopened = ChatContext(self.temp.name)
        found = reopened.search('color')['results']
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]['run_id'], run)
        self.assertNotIn('Do not duplicate', found[0]['transcript_excerpt'])
        self.assertEqual(reopened.path.stat().st_mode & 0o777, 0o600)

    def test_recent_context_is_bounded_but_old_turn_remains_searchable(self):
        self.turn('最初的设计约定是紫色', 'Use purple.')
        for i in range(25):
            self.turn('Request ' + str(i), 'Answer ' + str(i) + 'x' * 1000)
        self.next_turn()
        history = self.context.history()
        self.assertLessEqual(len(json.dumps(history, ensure_ascii=False)), 8000)
        self.assertNotIn('最初', json.dumps(history, ensure_ascii=False))
        self.assertEqual(len(self.context.search('紫色')['results']), 1)
        self.assertEqual(len(self.context.search('Request', offset=20, limit=10)['results']), 5)

    def test_compaction_keeps_tool_pairs_or_replaces_whole_group(self):
        messages = [
            {'role': 'user', 'content': 'Research'},
            {'role': 'assistant', 'content': '', 'tool_calls': [{'id': 'call1', 'type': 'function', 'function': {'name': 'read_webpage', 'arguments': '{}'}}]},
            {'role': 'tool', 'tool_call_id': 'call1', 'content': 'x' * 20000},
            {'role': 'assistant', 'content': 'Verified result'},
        ]
        self.turn('Research', 'Verified result', result_messages=messages)
        self.next_turn()
        history = self.context.history()
        self.assertEqual([m['role'] for m in history], ['user', 'assistant'])
        self.assertIn('Verified result', history[-1]['content'])
        self.assertIn('xxxx', self.context.search('xxxx')['results'][0]['transcript_excerpt'])

    def test_short_tool_groups_are_preserved_exactly(self):
        messages = [{'role': 'user', 'content': 'Read'},
                    {'role': 'assistant', 'tool_calls': [{'id': 'a', 'type': 'function', 'function': {'name': 'read_document', 'arguments': '{}'}}]},
                    {'role': 'tool', 'tool_call_id': 'a', 'content': 'facts'},
                    {'role': 'assistant', 'content': 'Done'}]
        self.turn('Read', 'Done', result_messages=messages)
        self.next_turn()
        self.assertEqual(self.context.history(), messages)

    def test_interrupted_attempts_and_execution_evidence_survive_restart(self):
        run = str(uuid.uuid4())
        self.context.begin(run, str(uuid.uuid4()), 'Send exactly once')
        self.context.record('tool_started', {'name': 'mac_action', 'arguments': {'text': 'Hello'}})
        reopened = ChatContext(self.temp.name)
        reopened.begin(str(uuid.uuid4()), str(uuid.uuid4()), 'Continue')
        self.assertIn('never repeat an uncertain commit', reopened.instructions())
        self.assertEqual(reopened.search('Send')['results'][0]['status'], 'interrupted')
        with closing(sqlite3.connect(reopened.path)) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM events WHERE run_id=?', (run,)).fetchone()[0], 1)

    def test_search_does_not_interpret_sql_or_wildcards(self):
        self.turn('Plain request', 'Plain answer')
        self.next_turn()
        self.assertEqual(self.context.search("' OR 1=1 --")['results'], [])
        self.assertEqual(self.context.search('%')['results'], [])

    def test_maximum_reply_size_and_limit_are_bounded(self):
        for i in range(25):
            self.turn('A' * 10000, 'B' * 20000)
        self.next_turn()
        result = self.context.search('', limit=1000)
        self.assertLess(len(json.dumps(result)), 20000)
        self.assertLessEqual(len(result['results']), 20)


if __name__ == '__main__':
    unittest.main()
