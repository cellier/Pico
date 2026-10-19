import copy
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
import uuid
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from hermes_result import PHONE_RESUME_INSTRUCTIONS, preserve_turn, turn_boundary
import worker


class HermesResultTests(unittest.TestCase):
    def test_only_completed_nonempty_unflagged_result_is_success(self):
        good = {'completed': True, 'final_response': '已完成。', 'messages': []}
        self.assertIsNone(turn_boundary(good))
        bad = [{'completed': False}, {'failed': True}, {'partial': True},
               {'interrupted': True}, {'error': 'provider failed'},
               {'final_response': ''}, {'final_response': '  '}, {'final_response': None},
               {'final_response': []}, {'completed': 'true'}, {'completed': 1},
               {'turn_exit_reason': 'guardrail_halt'}]
        for override in bad:
            with self.subTest(override=override):
                result = turn_boundary({**good, **override})
                self.assertEqual(result['status'], 'needs_input')
                self.assertNotIn('已完成。', result['text'])
        for malformed in (None, [], '', 1):
            self.assertIn('没有返回有效结果', turn_boundary(malformed)['text'])

    def test_max_iterations_has_real_reason_without_trusting_summary(self):
        result = {'completed': False, 'failed': False, 'partial': False,
                  'turn_exit_reason': 'max_iterations_reached(50/50)', 'api_calls': 50,
                  'final_response': '消息已发送，任务全部完成。'}
        notice = turn_boundary(result, phone_used=True)
        self.assertIn('50 轮执行上限', notice['text'])
        self.assertIn('实际发送状态', notice['text'])
        self.assertIn('避免重复发送', notice['text'])
        self.assertNotIn('消息已发送', notice['text'])
        self.assertTrue(notice['phone_may_have_acted'])

    def test_incomplete_reason_families_and_empty_unfailed_result(self):
        cases = [({'interrupted': True}, '已中断'),
                 ({'partial': True}, '部分操作'),
                 ({'turn_exit_reason': 'local_processing_error(bad image)'}, '消息处理'),
                 ({'failure_reason': 'loop_error'}, '流程出现异常'),
                 ({'failure_reason': 'context_overflow'}, '会话内容'),
                 ({'failure_reason': 'session_busy'}, '仍占用'),
                 ({'failure_reason': 'empty_response'}, '未返回完整回复'),
                 ({'turn_exit_reason': 'budget_exhausted'}, '执行额度'),
                 ({'turn_exit_reason': 'guardrail_halt'}, '执行保护'),
                 ({'failed': False, 'partial': False}, '提前停止')]
        for flags, expected in cases:
            with self.subTest(flags=flags):
                result = turn_boundary({'completed': False, 'final_response': 'optimistic claim', **flags})
                self.assertIn(expected, result['text'])
                self.assertEqual(result['status'], 'needs_input')
        self.assertIn('没有返回完整结果', turn_boundary({'completed': False, 'failed': False})['text'])

    def test_provider_error_detail_is_bounded_and_redacted(self):
        message = 'HTTP 401 sk-secretstuff Bearer privatevalue api_key=abc token=def ' + 'x' * 600
        result = turn_boundary({'completed': False, 'failed': True, 'error': message})
        self.assertIn('HTTP 401', result['text'])
        for secret in ('sk-secretstuff', 'privatevalue', 'api_key=abc', 'token=def'):
            self.assertNotIn(secret, result['text'])
        self.assertLess(len(result['text']), 260)

    @staticmethod
    def phone_call():
        return {'role': 'assistant', 'content': None,
                'tool_calls': [{'id': 'call-phone', 'type': 'function',
                                'function': {'name': 'phone_exec', 'arguments': '{"code":"print(1)"}'}}]}

    def test_phone_detection_only_uses_current_turn(self):
        base = {'completed': False, 'turn_exit_reason': 'max_iterations_reached(50/50)'}
        old_phone = [{'role': 'user', 'content': 'Old task'}, self.phone_call(),
                     {'role': 'assistant', 'content': 'Old result'},
                     {'role': 'user', 'content': 'Current task'}]
        self.assertFalse(turn_boundary({**base, 'messages': old_phone})['phone_may_have_acted'])
        self.assertTrue(turn_boundary({**base, 'messages': old_phone + [self.phone_call()]})['phone_may_have_acted'])
        self.assertTrue(turn_boundary({**base, 'messages': old_phone, 'current_turn_user_idx': 0})['phone_may_have_acted'])
        self.assertTrue(turn_boundary(None, phone_used=True)['phone_may_have_acted'])
        self.assertIn('实际发送状态', turn_boundary(None, phone_used=True)['text'])

    def test_history_roundtrip_is_exact_before_boundary_is_returned(self):
        messages = [{'role': 'user', 'content': 'request'}, self.phone_call(),
                    {'role': 'tool', 'tool_call_id': 'call-phone',
                     'content': [{'type': 'text', 'text': '{"success":true}'},
                                 {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,AA=='}}]},
                    {'role': 'assistant', 'content': 'partial', 'reasoning_content': 'retained',
                     'display_metadata': {'arbitrary': [1, True, None]}}]
        original = copy.deepcopy(messages)
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'history.json'
            boundary = preserve_turn({'messages': messages, 'completed': False}, path, worker.atomic_json)
            self.assertEqual(json.loads(path.read_text()), original)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(messages, original)
            self.assertEqual(boundary['status'], 'needs_input')
            # A missing/malformed transcript must never erase the known history.
            for result in (None, {}, {'messages': None}, {'messages': 'bad'}):
                preserve_turn(result, path, worker.atomic_json)
                self.assertEqual(json.loads(path.read_text()), original)

    def test_resume_instruction_requires_verification_before_repeat_send(self):
        self.assertIn('First inspect the current phone state', PHONE_RESUME_INSTRUCTIONS)
        self.assertIn('Never repeat a send', PHONE_RESUME_INSTRUCTIONS)
        self.assertIn('ask the user to check', PHONE_RESUME_INSTRUCTIONS)


class WorkerIncompleteIntegrationTests(unittest.TestCase):
    def test_worker_saves_partial_history_emits_needs_input_and_resumes_from_checkpoint(self):
        tools = {}
        transcripts = []
        messages = [{'role': 'user', 'content': 'send once'}, HermesResultTests.phone_call(),
                    {'role': 'tool', 'tool_call_id': 'call-phone', 'content': '{"success":true}'},
                    {'role': 'assistant', 'content': 'Unsafe optimistic completion claim.'}]

        class Registry:
            def register(self, **values):
                tools[values['name']] = values['handler']

        class Agent:
            def __init__(self, **kwargs):
                self.options = kwargs

            def run_conversation(self, prompt, **kwargs):
                transcripts.append(kwargs)
                self.options['tool_start_callback']('call-phone', 'phone_exec', {})
                self.options['tool_complete_callback']('call-phone', 'phone_exec', {}, '{}')
                tools['report_outcome']({'status': 'ready', 'summary': 'Incorrect success'})
                return {'completed': False, 'failed': False, 'final_response': 'Incorrect success',
                        'messages': messages, 'turn_exit_reason': 'max_iterations_reached(50/50)'}

        registry_module = types.ModuleType('tools.registry')
        registry_module.registry = Registry()
        agent_module = types.ModuleType('run_agent')
        agent_module.AIAgent = Agent
        previous_cwd = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temp:
            data = Path(temp)
            task_id = str(uuid.uuid4())
            (data / 'config.json').write_text(json.dumps({'api_key': 'fake', 'base_url': 'http://127.0.0.1:1', 'model': 'fixture'}))
            request = {'task_id': task_id, 'new': False, 'prompt': 'test only', 'auto_approve': True}
            try:
                for _ in range(2):
                    output = io.StringIO()
                    with patch.dict(sys.modules, {'run_agent': agent_module, 'tools.registry': registry_module}), \
                         patch.dict(os.environ, {'TELOS_DATA_DIR': str(data)}), \
                         patch('sys.stdin', io.StringIO(json.dumps(request))), \
                         patch.object(worker, 'OUT', output), patch('openai.OpenAI') as client, \
                         patch('phone_bridge.prepare_phone_home', return_value=True), \
                         patch('phone_bridge.PhoneBridge.attach', return_value=True):
                        # No plugin or phone execution occurs: only the real worker boundary is under test.
                        worker.main()
                        client.return_value.chat.completions.create.assert_not_called()
                    events = [json.loads(line) for line in output.getvalue().splitlines()]
                    self.assertEqual(events[-1]['type'], 'done')
                    self.assertEqual(events[-1]['status'], 'needs_input')
                    self.assertIn('50 轮执行上限', events[-1]['text'])
                    self.assertIn('避免重复发送', events[-1]['text'])
                    self.assertNotIn('Incorrect success', events[-1]['text'])
                path = data / 'tasks' / task_id
                self.assertEqual(json.loads((path / 'history.json').read_text()), messages)
                checkpoint = json.loads((path / 'last-turn.json').read_text())
                self.assertTrue(checkpoint['phone_may_have_acted'])
                self.assertEqual(transcripts[-1]['conversation_history'], messages)
                self.assertIn('PHONE RESUME', transcripts[-1]['system_message'])
            finally:
                os.chdir(previous_cwd)


if __name__ == '__main__':
    unittest.main()
