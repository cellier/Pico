"""Real worker routing with a fake agent/model: no network or paid requests."""
import io
import json
import os
import sys
import tempfile
import types
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
import worker
from chat_context import ChatContext


class ChatWorkerTests(unittest.TestCase):
    def test_chat_uses_full_tools_streams_and_recovers_context_without_a_todo(self):
        tools, calls, agent_options = {}, [], []

        class Registry:
            def register(self, **values):
                tools[values['name']] = values['handler']

        class Agent:
            def __init__(self, **options):
                self.options = options
                agent_options.append(options)

            def run_conversation(self, prompt, **options):
                calls.append(options)
                self.options['stream_delta_callback']('Hello ')
                self.options['stream_delta_callback']('again')
                self.options['tool_start_callback']('file1', 'save_document', {'name': 'result.md'})
                tools['save_document']({'name': 'result.md', 'content': 'An actual generated deliverable'})
                self.options['tool_complete_callback']('file1', 'save_document', {}, {'saved': True})
                history = options['conversation_history']
                return {'completed': True, 'final_response': 'Hello again',
                        'messages': history + [{'role': 'user', 'content': prompt},
                                               {'role': 'assistant', 'content': 'Hello again'}],
                        'current_turn_user_idx': len(history)}

        registry_module, agent_module = types.ModuleType('tools.registry'), types.ModuleType('run_agent')
        registry_module.registry = Registry(); agent_module.AIAgent = Agent
        original_cwd = Path.cwd()
        with tempfile.TemporaryDirectory() as temp:
            data = Path(temp)
            (data / 'config.json').write_text(json.dumps({'api_key': 'fake', 'base_url': 'http://127.0.0.1:1', 'model': 'fixture'}))
            conversation = str(uuid.uuid4())
            try:
                for prompt in ('Remember indigo', 'What color did we choose?'):
                    request = {'mode': 'chat', 'task_id': conversation, 'run_id': str(uuid.uuid4()),
                               'message_id': str(uuid.uuid4()), 'prompt': prompt, 'new': False, 'auto_approve': False}
                    output = io.StringIO()
                    with patch.dict(sys.modules, {'run_agent': agent_module, 'tools.registry': registry_module}), \
                         patch.dict(os.environ, {'TELOS_DATA_DIR': str(data)}), \
                         patch('sys.stdin', io.StringIO(json.dumps(request))), \
                         patch.object(worker, 'OUT', output), patch('openai.OpenAI') as client, \
                         patch('phone_bridge.prepare_phone_home', return_value=False), \
                         patch('phone_bridge.PhoneBridge.attach', return_value=False):
                        worker.main()
                        client.return_value.chat.completions.create.assert_not_called()
                    events = [json.loads(line) for line in output.getvalue().splitlines()]
                    self.assertEqual([e['text'] for e in events if e['type'] == 'delta'], ['Hello ', 'again'])
                    self.assertEqual(events[-1]['type'], 'done')
                    self.assertEqual(events[-1]['status'], 'ready')
                    self.assertTrue(any(e['type'] == 'artifact' for e in events))
                self.assertFalse((data / 'tasks').exists())
                self.assertFalse((data / 'tasks.json').exists())
                directory = data / 'chats' / conversation
                self.assertEqual((directory / 'files/result.md').read_text(), 'An actual generated deliverable')
                physical = (data / 'PicoFiles/Chats' / conversation).resolve()
                self.assertEqual((directory / 'files').resolve(), physical)
                self.assertFalse(physical.is_symlink())
                self.assertEqual(agent_options[-1]['cwd'], str(physical))
                self.assertEqual(worker.ACTIVE_PHONE.workspace, physical)
                self.assertTrue(all(Path(e['path']).parent == physical for e in events if e['type'] == 'artifact'))
                self.assertIn('Remember indigo', json.dumps(calls[-1]['conversation_history']))
                self.assertIn('You are Pico', calls[-1]['system_message'])
                self.assertIn('search_chat_history', tools)
                self.assertIn('create_tasks', tools)
                self.assertIn('mac_action', tools)
                self.assertIn('approve_work_plan', tools)
                self.assertIn('run_python', tools)
                self.assertEqual(len(ChatContext(directory).search('indigo')['results']), 1)
            finally:
                os.chdir(original_cwd)
                worker.ACTIVE_CHAT = None


if __name__ == '__main__':
    unittest.main()
