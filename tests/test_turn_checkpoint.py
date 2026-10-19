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
from turn_checkpoint import TurnCheckpoint
import worker


class TurnCheckpointTests(unittest.TestCase):
    def test_exact_terminal_event_is_durable_before_native_emission(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'task/last-turn.json'
            run_id = str(uuid.uuid4()).upper()
            checkpoint = TurnCheckpoint(path, run_id, worker.atomic_json)
            values = {'text': '需要你核对手机。', 'status': 'needs_input', 'summary': '请核对实际结果。'}

            def emitted(kind, **event):
                saved = json.loads(path.read_text())
                self.assertEqual(saved['run_id'], run_id.lower())
                self.assertEqual(saved['event'], {'type': kind, **event})
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

            with patch.object(worker, 'ACTIVE_TURN', checkpoint), patch.object(worker, 'emit', side_effect=emitted):
                worker.emit_final('done', **values)
            # Broken stdout after a durable result must not turn it into a failure.
            before = path.read_bytes()
            checkpoint.record('error', {'text': 'Broken pipe'})
            self.assertEqual(path.read_bytes(), before)

    def test_legacy_request_has_no_recoverable_run_id_but_retains_phone_warning(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'last-turn.json'
            checkpoint = TurnCheckpoint(path, None, worker.atomic_json)
            checkpoint.phone_may_have_acted = True
            checkpoint.turn_exit_reason = 'max_iterations_reached(50/50)'
            checkpoint.record('done', {'text': 'Check the phone first.', 'status': 'needs_input', 'summary': 'Stopped'})
            saved = json.loads(path.read_text())
            self.assertNotIn('run_id', saved)
            self.assertTrue(saved['phone_may_have_acted'])
            self.assertEqual(saved['turn_exit_reason'], 'max_iterations_reached(50/50)')

    def test_invalid_run_identity_is_rejected(self):
        for invalid in ('', 'previous-turn', 'run/../../task'):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                TurnCheckpoint('/unused/last-turn.json', invalid, worker.atomic_json)

    def test_top_level_failure_writes_same_redacted_error_and_survives_disk_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'last-turn.json'
            checkpoint = TurnCheckpoint(path, str(uuid.uuid4()), worker.atomic_json)
            checkpoint.phone_may_have_acted = True
            output = io.StringIO()
            with patch.object(worker, 'ACTIVE_TURN', checkpoint), patch.object(worker, 'OUT', output):
                worker.report_failure(RuntimeError('failure sk-privatefixture'))
            event = json.loads(output.getvalue())
            saved = json.loads(path.read_text())
            self.assertEqual(saved['event'], event)
            self.assertEqual(saved['status'], 'error')
            self.assertTrue(saved['phone_may_have_acted'])
            self.assertNotIn('sk-privatefixture', path.read_text() + output.getvalue())
            broken = TurnCheckpoint(path, str(uuid.uuid4()), lambda *_: (_ for _ in ()).throw(OSError('Disk full')))
            output = io.StringIO()
            with patch.object(worker, 'ACTIVE_TURN', broken), patch.object(worker, 'OUT', output):
                worker.report_failure(RuntimeError('Native must receive this.'))
            self.assertEqual(json.loads(output.getvalue())['type'], 'error')


class WorkerFinalCheckpointTests(unittest.TestCase):
    def run_scenario(self, scenario):
        tools = {}
        class Registry:
            def register(self, **values):
                tools[values['name']] = values['handler']
        class Agent:
            def __init__(self, **kwargs):
                self.options = kwargs
            def run_conversation(self, prompt, **kwargs):
                if scenario != 'classified':
                    tools['report_outcome']({'status': 'ready', 'summary': 'Engine result'})
                if scenario == 'denied':
                    worker.ACTIVE_CAP.denied = True
                if scenario == 'draft':
                    folder = Path.cwd() / '.presentations/draft'
                    folder.mkdir(parents=True)
                    (folder/'manifest.json').write_text('{}')
                if scenario == 'partial':
                    self.options['tool_start_callback']('phone-call', 'phone_exec', {})
                    return {'completed': False, 'messages': [], 'turn_exit_reason': 'max_iterations_reached(50/50)'}
                return {'completed': True, 'messages': [], 'final_response': '实际结果。'}
        registry_module = types.ModuleType('tools.registry'); registry_module.registry = Registry()
        agent_module = types.ModuleType('run_agent'); agent_module.AIAgent = Agent
        previous_cwd = Path.cwd()
        with tempfile.TemporaryDirectory() as temp:
            data = Path(temp); task_id = str(uuid.uuid4()); run_id = str(uuid.uuid4())
            (data/'config.json').write_text(json.dumps({'api_key': 'fixture-only', 'base_url': 'http://127.0.0.1:1', 'model': 'fixture'}))
            request = {'task_id': task_id, 'run_id': run_id, 'new': False, 'prompt': 'test', 'auto_approve': True}
            output = io.StringIO()
            try:
                with patch.dict(sys.modules, {'run_agent': agent_module, 'tools.registry': registry_module}), \
                     patch.dict(os.environ, {'TELOS_DATA_DIR': str(data)}), \
                     patch('sys.stdin', io.StringIO(json.dumps(request))), \
                     patch.object(worker, 'OUT', output), patch('openai.OpenAI') as client, \
                     patch('phone_bridge.prepare_phone_home', return_value=False), \
                     patch('phone_bridge.PhoneBridge.attach', return_value=False):
                    reply = json.dumps({'status': 'needs_input', 'summary': 'Classification requires input'})
                    client.return_value.chat.completions.create.return_value = types.SimpleNamespace(
                        choices=[types.SimpleNamespace(message=types.SimpleNamespace(content=reply))])
                    worker.main()
                event = json.loads(output.getvalue().splitlines()[-1])
                saved = json.loads((data/'tasks'/task_id/'last-turn.json').read_text())
                self.assertEqual(saved['run_id'], run_id)
                self.assertEqual(saved['event'], event)
                self.assertEqual(saved['status'], event['status'])
                return event, saved
            finally:
                os.chdir(previous_cwd)

    def test_final_gates_not_engine_completion_decide_saved_status(self):
        for scenario in ('ready', 'classified', 'denied', 'draft', 'partial'):
            with self.subTest(scenario=scenario):
                event, saved = self.run_scenario(scenario)
                self.assertEqual(event['status'], 'ready' if scenario == 'ready' else 'needs_input')
                if scenario == 'draft':
                    self.assertIn('仍是草稿', event['text'])
                if scenario == 'partial':
                    self.assertTrue(saved['phone_may_have_acted'])
                    self.assertIn('避免重复发送', event['text'])


if __name__ == '__main__':
    unittest.main()
