"""Exercise title request wiring and saved-task payloads without model/network calls."""
import io
import json
import os
import sys
import tempfile
import threading
import types
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
import worker
from task_creation import register_task_creation


class TaskTitleLanguageTests(unittest.TestCase):
    def run_worker(self, prompt, model_title, *, new=True):
        registered, execution = {}, {}

        class Registry:
            def register(self, **values):
                registered[values['name']] = values

        class Agent:
            def __init__(self, **options):
                execution['agent_options'] = options

            def run_conversation(self, value, **options):
                execution.update(prompt=value, system=options['system_message'])
                execution['automatic_execution'] = worker.ACTIVE_PHONE.gate.auto_approve
                registered['report_outcome']['handler']({'status': 'ready', 'summary': 'Fixture result ready'})
                history = options['conversation_history']
                return {'completed': True, 'final_response': 'Fixture body stays unchanged.',
                        'messages': history + [{'role': 'user', 'content': value},
                                               {'role': 'assistant', 'content': 'Fixture body stays unchanged.'}],
                        'current_turn_user_idx': len(history)}

        registry_module = types.ModuleType('tools.registry')
        registry_module.registry = Registry()
        agent_module = types.ModuleType('run_agent')
        agent_module.AIAgent = Agent
        original_cwd = Path.cwd()
        globals_before = {key: getattr(worker, key) for key in
                          ('ACTIVE_CAP', 'ACTIVE_PHONE', 'ACTIVE_TURN', 'ACTIVE_CHAT', 'ACTIVE_CONTINUOUS')}
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'config.json').write_text(json.dumps({
                'api_key': 'fixture-not-a-real-key', 'base_url': 'http://127.0.0.1:1', 'model': 'title-fixture'}))
            request = {'task_id': str(uuid.uuid4()), 'run_id': str(uuid.uuid4()),
                       'prompt': prompt, 'new': new, 'auto_approve': False}
            try:
                with patch.dict(sys.modules, {'run_agent': agent_module, 'tools.registry': registry_module}), \
                     patch.dict(os.environ, {'TELOS_DATA_DIR': str(directory)}), \
                     patch('sys.stdin', io.StringIO(json.dumps(request, ensure_ascii=False))), \
                     patch.object(worker, 'OUT', output), patch('openai.OpenAI') as client, \
                     patch('phone_bridge.prepare_phone_home', return_value=False), \
                     patch('phone_bridge.PhoneBridge.attach', return_value=False), \
                     patch('mac_bridge.MacBridge.action', side_effect=AssertionError('No real app actions in fixture')):
                    completion = client.return_value.chat.completions.create
                    completion.return_value = types.SimpleNamespace(choices=[types.SimpleNamespace(
                        message=types.SimpleNamespace(content=model_title))])
                    worker.main()
                    model_calls = list(completion.call_args_list)
            finally:
                os.chdir(original_cwd)
                for key, value in globals_before.items():
                    setattr(worker, key, value)
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        return model_calls, execution, registered, events

    def assert_contextual_title_policy(self, text):
        self.assertRegex(text.lower(), r'language')
        self.assertRegex(text.lower(), r'(request|user)')
        self.assertNotRegex(text, r'(?i)(in English, regardless|natural English action title|'
                                 r'concise English titles|task titles alone are English|Short English task title)')

    def test_new_task_passes_current_language_and_keeps_title_response_verbatim(self):
        cases = [
            ('给 Zoom Slides 下一版本做排期', '规划 Zoom Slides 下一版本排期'),
            ('Prepare the Allhands progress deck for Thursday', 'Prepare Thursday Allhands progress deck'),
            ('周四 Allhands 前整理 slides 的进展', '准备 Allhands 进展介绍'),
            ('建一个任务，标题就叫 Launch Readiness', 'Launch Readiness'),
            ('Create a task titled「周四进展介绍」and save it.', '周四进展介绍'),
            ('来週のリリース計画を整理して', '来週のリリース計画を整理'),
        ]
        for prompt, title in cases:
            with self.subTest(prompt=prompt):
                calls, execution, tools, events = self.run_worker(prompt, title)
                self.assertEqual(len(calls), 1, 'Naming must not trigger a second execution/classification request')
                messages = calls[0].kwargs['messages']
                self.assertEqual(messages[1], {'role': 'user', 'content': prompt})
                self.assert_contextual_title_policy(messages[0]['content'])
                self.assert_contextual_title_policy(execution['system'])
                self.assertEqual(execution['prompt'], prompt, 'Naming must not translate or rewrite the execution request')
                self.assertEqual([e['text'] for e in events if e['type'] == 'title'], [title])
                self.assertEqual(events[-1]['text'], 'Fixture body stays unchanged.')
                self.assertEqual(events[-1]['status'], 'ready')
                self.assertFalse(execution['automatic_execution'], 'Language must not change the execution setting')
                title_schema = tools['create_tasks']['schema']['parameters']['properties']['tasks']['items']['properties']['title']
                self.assert_contextual_title_policy(title_schema['description'])

    def test_continuation_does_not_rename_an_existing_task(self):
        calls, execution, _, events = self.run_worker('继续这个任务，补上中文说明。', 'Unexpected title', new=False)
        self.assertFalse(calls)
        self.assertFalse(any(event['type'] == 'title' for event in events))
        self.assertEqual(execution['prompt'], '继续这个任务，补上中文说明。')

    def test_chinese_saved_title_and_source_acknowledgement_are_not_rewritten(self):
        current_source = str(uuid.uuid4())
        recorded, events = {}, []

        def source_validator(value):
            if value != current_source:
                raise ValueError('Only the current explicit user request may create tasks')
            return value

        class Gate:
            lock = threading.Lock()

            def read_reply(self, timeout, *, request_id):
                return {'request_id': request_id, 'status': 'saved_not_started'}

        def register(name, description, properties, required, handler):
            recorded.update(description=description, properties=properties, required=required, handler=handler)

        register_task_creation(register, lambda kind, **values: events.append((kind, values)), Gate(),
                               source_validator=source_validator)
        proposals = [{'title': '规划 Zoom Slides 下一版本排期', 'instructions': '只保存待办，不要开始执行。'},
                     {'title': 'Launch Readiness', 'instructions': '用户明确指定这个英文标题。'}]
        result = recorded['handler']({'source_message_id': current_source, 'tasks': proposals})
        self.assertEqual(result['status'], 'saved_not_started')
        self.assertEqual(events[0][0], 'create_tasks')
        self.assertEqual(events[0][1]['tasks'], proposals)
        self.assertEqual(events[0][1]['source_message_id'], current_source)
        self.assert_contextual_title_policy(recorded['properties']['tasks']['items']['properties']['title']['description'])
        for payload in ({'source_message_id': str(uuid.uuid4()), 'tasks': proposals},
                        {'source_message_id': current_source, 'tasks': proposals * 3}):
            with self.assertRaises(ValueError):
                recorded['handler'](payload)
        self.assertEqual(len(events), 1, 'Invalid source or more than five tasks must not emit another creation')


if __name__ == '__main__':
    unittest.main()
