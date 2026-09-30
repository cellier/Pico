import sys
import unittest
import threading
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from task_creation import register_task_creation

class TaskCreationTests(unittest.TestCase):
    def setup_tool(self, confirmed=True):
        events = []
        class Gate:
            lock = threading.Lock()
            def reader(self, timeout):
                return {'request_id': events[-1][1]['request_id'], 'status': 'saved_not_started'} if confirmed else None
        handlers = {}
        register_task_creation(lambda name, desc, props, required, handler: handlers.update({name: handler}), lambda kind, **args: events.append((kind, args)), Gate())
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
