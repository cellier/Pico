import io
import json
import os
import sys
import tempfile
import threading
import time
import types
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Backend'))
from continuous_chat import ChatInputDispatcher, ContinuousChat, validate_messages, reconcile_coverage
from mac_bridge import ApprovalGate
from task_creation import register_task_creation
from chat_context import ChatContext
from turn_checkpoint import TurnCheckpoint


class FakeAgent:
    def __init__(self, redirect=True):
        self.redirected, self.steered, self.flushed = [], [], []
        self.accept_redirect = redirect

    def redirect(self, text):
        self.redirected.append(text)
        return self.accept_redirect

    def steer(self, text):
        self.steered.append(text)
        return True

    def _flush_messages_to_session_db(self, messages, *args, **kwargs):
        self.flushed.append(messages)
        return True


class ContinuousChatTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.run = str(uuid.uuid4())
        self.first, self.second = str(uuid.uuid4()), str(uuid.uuid4())
        self.events = []
        self.request = {'run_id': self.run, 'messages': [
            {'id': self.first.upper(), 'text': '帮我写一个方案', 'voice': True, 'language': 'zh'}]}

    def make(self, **options):
        session = ContinuousChat(self.request, self.directory, lambda kind, **values: self.events.append((kind, values)))
        agent, gate = FakeAgent(**options), ApprovalGate(lambda *a, **k: None)
        session.attach(agent, gate, io.StringIO(''))
        session.dispatcher.thread.join(1)
        return session, agent, gate

    def row(self, session, *ids):
        return {'role': 'user', 'content': session.prompt(ids or [self.first])}

    def test_validation_is_bounded_and_uuid_identity_cannot_change(self):
        self.assertEqual(validate_messages(self.request['messages'])[0]['id'], self.first)
        for value in ([], [{}], [{'id': self.first, 'text': 'a'}] * 2,
                      [{'id': self.first, 'text': 'a' * 100001}]):
            with self.subTest(value=str(value)[:60]), self.assertRaises(ValueError):
                validate_messages(value)
        session, _, _ = self.make()
        with self.assertRaises(ValueError):
            session.receive([{'id': self.first, 'text': 'Different text'}])

    def test_submission_is_not_consumption_and_late_steer_stays_unhandled(self):
        session, agent, _ = self.make(redirect=False)
        initial = self.row(session)
        agent._flush_messages_to_session_db([initial])
        session.receive([{'id': self.second, 'text': '更简洁一点'}])
        self.assertEqual(len(agent.steered), 1)
        self.assertEqual(session.consumed, {self.first})
        with self.assertRaises(ValueError):
            session.require_current_context()
        fields = session.finish({'messages': [initial], 'pending_steer': agent.steered[0]}, 'First reply')
        self.assertEqual(fields['handled_message_ids'], [self.first])
        self.assertNotIn(self.second, fields['consumed_message_ids'])
        self.assertTrue(any(kind == 'chat_message_accepted' for kind, _ in self.events))
        before = len(agent.steered)
        session.receive([{'id': str(uuid.uuid4()), 'text': 'Arrived after final'}])
        self.assertEqual(len(agent.steered), before)

    def test_only_exact_real_user_envelopes_prove_consumption(self):
        session, agent, _ = self.make()
        envelope = session.prompt()
        session.observe([{'role': 'assistant', 'content': envelope}, {'role': 'tool', 'content': envelope},
                         {'role': 'user', 'content': self.first}])
        self.assertEqual(session.consumed, set())
        agent._flush_messages_to_session_db([self.row(session)])
        session.receive([{'id': self.second, 'text': 'Change direction without killing the whole worker'}])
        self.assertEqual(agent.redirected, [session.prompt([self.second])])
        self.assertFalse(agent.steered)
        session.observe([self.row(session), self.row(session, self.second)])
        session.require_current_context()
        consumed = [value['message_ids'] for kind, value in self.events if kind == 'chat_messages_consumed']
        self.assertEqual(consumed, [[self.first], [self.second]])
        session.observe([self.row(session), self.row(session, self.second)])
        self.assertEqual(len([kind for kind, _ in self.events if kind == 'chat_messages_consumed']), 2)

    def test_related_messages_share_one_reply_and_tool_final_never_duplicates(self):
        session, _, _ = self.make()
        session.receive([{'id': self.second, 'text': 'Use three bullets'}])
        rows = [self.row(session), self.row(session, self.second)]
        session.observe(rows)
        reply = session.send_reply({'text': 'One coherent answer', 'reply_to': [self.first, self.second]})
        self.assertTrue(reply['delivered'])
        journal = json.loads((self.directory / 'reply-journal' / (self.run + '.json')).read_text())
        self.assertEqual(journal['replies'][0]['message_id'], reply['message_id'])
        self.assertEqual((self.directory / 'reply-journal' / (self.run + '.json')).stat().st_mode & 0o777, 0o600)
        fields = session.finish({'messages': rows}, 'One coherent answer')
        self.assertEqual(fields['text'], '')
        self.assertEqual(fields['reply_to'], [])
        self.assertEqual(fields['handled_message_ids'], [self.first, self.second])
        self.assertEqual(fields['delivered_replies'], journal['replies'])
        with self.assertRaises(ValueError):
            session.send_reply({'text': 'duplicate', 'reply_to': [self.first]})

    def test_independent_messages_get_separate_stable_reply_ids(self):
        session, _, _ = self.make()
        session.receive([{'id': self.second, 'text': 'Another unrelated question'}])
        rows = [self.row(session), self.row(session, self.second)]
        session.observe(rows)
        first = session.send_reply({'text': 'First result', 'reply_to': [self.first]})
        second = session.send_reply({'text': 'Second result', 'reply_to': [self.second]})
        self.assertNotEqual(first['message_id'], second['message_id'])
        self.assertEqual(first['message_id'], str(uuid.uuid5(uuid.UUID(self.run), 'chat-reply-0')))
        fields = session.finish({'messages': rows}, 'Do not repeat these results')
        checkpoint = TurnCheckpoint(self.directory / 'last-turn.json', self.run,
                                    lambda path, value: path.write_text(json.dumps(value)))
        checkpoint.record('done', dict(status='ready', summary='Ready', **fields))
        saved = json.loads((self.directory / 'last-turn.json').read_text())['event']
        self.assertEqual(saved['handled_message_ids'], [self.first, self.second])
        self.assertEqual(saved['delivered_replies'][1]['message_id'], second['message_id'])
        self.assertEqual(saved['text'], '')

    def test_unanswered_message_is_not_swallowed_by_empty_final(self):
        session, _, _ = self.make()
        session.receive([{'id': self.second, 'text': 'Second request'}])
        rows = [self.row(session), self.row(session, self.second)]
        session.observe(rows)
        session.send_reply({'text': 'Only answers the first request', 'reply_to': [self.first]})
        fields = session.finish({'messages': rows}, '')
        self.assertEqual(fields['handled_message_ids'], [self.first])
        self.assertEqual(fields['consumed_message_ids'], [self.first, self.second])
        self.assertEqual(fields['reply_to'], [])
        fields = session.finish({'messages': rows}, 'Already replied. Here is a duplicate sign-off.')
        self.assertEqual(fields['text'], '')
        self.assertEqual(fields['handled_message_ids'], [self.first])

    def test_coverage_updates_the_same_reply_durably_without_another_bubble(self):
        session, _, _ = self.make()
        session.receive([{'id': self.second, 'text': 'Replace the original request'}])
        rows = [self.row(session), self.row(session, self.second)]
        session.observe(rows)
        reply = session.send_reply({'text': 'Updated answer', 'reply_to': [self.second]})
        resolved = session.resolve_messages({'message_id': reply['message_id'], 'message_ids': [self.first]})
        self.assertTrue(resolved['resolved'])
        self.assertEqual(resolved['reply_to'], [self.second, self.first])
        self.assertEqual(len([kind for kind, _ in self.events if kind == 'chat_reply']), 1)
        coverage = [value for kind, value in self.events if kind == 'chat_reply_coverage']
        self.assertEqual(coverage, [{'message_id': reply['message_id'], 'reply_to': [self.second, self.first]}])
        session.resolve_messages({'message_id': reply['message_id'], 'message_ids': [self.first]})
        self.assertEqual(len([kind for kind, _ in self.events if kind == 'chat_reply_coverage']), 1)
        journal = json.loads((self.directory/'reply-journal'/(self.run+'.json')).read_text())
        self.assertEqual(journal['replies'][0]['message_id'], reply['message_id'])
        self.assertEqual(journal['replies'][0]['text'], 'Updated answer')
        fields = session.finish({'messages': rows}, 'Duplicate prose')
        self.assertEqual(fields['text'], '')
        self.assertEqual(set(fields['handled_message_ids']), {self.first, self.second})

    def test_coverage_rejects_invented_unconsumed_and_already_separately_answered_ids(self):
        session, _, _ = self.make()
        session.receive([{'id': self.second, 'text': 'Another request'}])
        session.observe([self.row(session), self.row(session, self.second)])
        first = session.send_reply({'text': 'One', 'reply_to': [self.first]})
        second = session.send_reply({'text': 'Two', 'reply_to': [self.second]})
        for args in ({'message_id': first['message_id'], 'message_ids': [self.second]},
                     {'message_id': second['message_id'], 'message_ids': [str(uuid.uuid4())]},
                     {'message_id': str(uuid.uuid4()), 'message_ids': [self.first]}):
            with self.subTest(args=args), self.assertRaises(ValueError):
                session.resolve_messages(args)
        self.assertFalse(any(kind == 'chat_reply_coverage' for kind, _ in self.events))

    def test_one_text_only_correction_keeps_real_history_and_never_replays_work(self):
        session, _, _ = self.make()
        session.receive([{'id': self.second, 'text': 'Stop the original; answer this instead'}])
        rows = [self.row(session), {'role': 'assistant', 'content': 'Already executed evidence'}, self.row(session, self.second)]
        session.observe(rows)
        delivered = session.send_reply({'text': 'Replacement result', 'reply_to': [self.second]})
        original = {'completed': True, 'messages': rows, 'final_response': 'Duplicate sign-off'}
        calls = []
        class Agent:
            run_budget_seconds = 900
            max_iterations = 50
            def run_conversation(self, prompt, **options):
                calls.append((prompt, options))
                self_test.assertEqual(self.valid_tool_names, {'send_chat_reply', 'resolve_chat_messages', 'report_outcome'})
                self_test.assertEqual(options['conversation_history'], rows)
                with self_test.assertRaises(ValueError):
                    session.require_current_context(tool='mac_action')
                session.require_current_context(tool='resolve_chat_messages')
                session.resolve_messages({'message_id': delivered['message_id'], 'message_ids': [self_test.first]})
                return {'completed': True, 'messages': rows + [{'role': 'user', 'content': prompt},
                        {'role': 'assistant', 'content': 'Internal acknowledgment'}],
                        'current_turn_user_idx': len(rows), 'final_response': 'Internal acknowledgment'}
        self_test = self
        registry = types.ModuleType('tools.registry')
        registry.registry = types.SimpleNamespace(get_entry=lambda name: types.SimpleNamespace(schema={'name': name}))
        agent = Agent()
        with patch.dict(sys.modules, {'tools.registry': registry}):
            corrected = reconcile_coverage(agent, session, original, 'Original system')
            reconcile_coverage(agent, session, original, 'Original system')
        self.assertEqual(len(calls), 1)
        self.assertLessEqual(agent.run_budget_seconds, 20)
        self.assertLessEqual(agent.max_iterations, 4)
        self.assertEqual(session.finish(corrected, corrected['final_response'])['text'], '')
        self.assertEqual(len([kind for kind, _ in self.events if kind == 'chat_reply']), 1)

    def test_unknown_unconsumed_targets_and_failed_journal_do_not_emit(self):
        session, _, _ = self.make()
        for key in (self.first, str(uuid.uuid4()), 'invalid'):
            with self.assertRaises(ValueError):
                session.send_reply({'text': 'Must not deliver', 'reply_to': [key]})
        session.observe([self.row(session)])
        (self.directory / 'reply-journal').write_text('A file blocks the journal directory')
        with self.assertRaises(OSError):
            session.send_reply({'text': 'Not durable', 'reply_to': [self.first]})
        self.assertFalse(any(kind == 'chat_reply' for kind, _ in self.events))
        self.assertEqual(session.replied, set())
        self.assertEqual(session.finish({'messages': [self.row(session)]}, '')['handled_message_ids'], [])

    def test_dispatcher_does_not_steal_approval_or_task_creation_replies(self):
        approval, task = str(uuid.uuid4()), str(uuid.uuid4())
        inputs = [dict(type='chat_message', run_id=str(uuid.uuid4()), messages=[{'id': self.second, 'text': 'Wrong run'}]),
                  dict(approval_id=approval, action_hash='hash', decision='approve'),
                  dict(type='chat_message', run_id=self.run, messages=[{'id': self.second, 'text': 'Follow-up'}]),
                  dict(request_id=task, status='saved_not_started')]
        accepted = []
        dispatcher = ChatInputDispatcher(io.StringIO('\n'.join(json.dumps(value) for value in inputs) + '\n'),
                                         self.run, lambda messages: accepted.extend(messages))
        dispatcher.start(); dispatcher.thread.join(1)
        self.assertEqual(accepted, [{'id': self.second, 'text': 'Follow-up'}])
        self.assertEqual(dispatcher.read_reply(0, request_id=task)['status'], 'saved_not_started')
        self.assertEqual(dispatcher.read_reply(0, approval_id=approval, action_hash='hash')['decision'], 'approve')
        self.assertIsNone(dispatcher.read_reply(0, request_id=task))

    def test_targeted_cancel_keeps_the_other_message_and_waits_for_real_control_context(self):
        session, agent, gate = self.make(redirect=False)
        session.receive([{'id': self.second, 'text': 'A typed independent question'}])
        rows = [self.row(session), self.row(session, self.second)]
        session.observe(rows)
        generation = gate.generation
        session.cancel_messages([self.first])
        self.assertEqual(session.withdrawn, {self.first})
        self.assertEqual(gate.generation, generation + 1)
        with self.assertRaises(ValueError):
            session.require_current_context()
        control = agent.steered[-1]
        self.assertIn('PICO_CANCEL', control)
        self.assertIn(self.first, control)
        self.assertNotIn(self.second, control)
        rows.append({'role': 'user', 'content': control})
        session.observe(rows)
        session.require_current_context()
        with self.assertRaises(ValueError):
            session.send_reply({'text': 'Do not answer withdrawn voice', 'reply_to': [self.first]})
        with self.assertRaises(ValueError):
            session.validate_source(self.first)
        session.send_reply({'text': 'The typed question still gets its answer', 'reply_to': [self.second]})
        fields = session.finish({'messages': rows}, 'No duplicate final')
        self.assertEqual(fields['text'], '')
        self.assertEqual(fields['withdrawn_message_ids'], [self.first])
        self.assertEqual(fields['handled_message_ids'], [self.first, self.second])
        self.assertEqual(fields['delivered_replies'][0]['reply_to'], [self.second])
        self.assertEqual(len([kind for kind, _ in self.events if kind == 'chat_reply']), 1)

    def test_cancel_crossing_final_does_not_misattribute_old_text_to_remaining_request(self):
        session, _, _ = self.make()
        session.receive([{'id': self.second, 'text': 'Independent remaining request'}])
        rows = [self.row(session), self.row(session, self.second)]
        session.observe(rows)
        session.cancel_messages([self.first])
        # The model result completed before it actually read the cancellation.
        fields = session.finish({'messages': rows}, 'Stale output from the withdrawn request')
        self.assertEqual(fields['text'], '')
        self.assertEqual(fields['handled_message_ids'], [self.first])
        self.assertNotIn(self.second, fields['handled_message_ids'])

    def test_cancel_dispatch_is_run_scoped_and_unknown_ids_cannot_withdraw_others(self):
        cancelled = []
        frames = [dict(type='chat_cancel', run_id=str(uuid.uuid4()), message_ids=[self.first]),
                  dict(type='chat_cancel', run_id=self.run, message_ids=['invalid']),
                  dict(type='chat_cancel', run_id=self.run, message_ids=[self.first, self.first])]
        dispatcher = ChatInputDispatcher(io.StringIO('\n'.join(json.dumps(frame) for frame in frames)+'\n'),
                                         self.run, lambda _: self.fail('Cancel must not become a chat message'),
                                         lambda ids: cancelled.append(ids))
        dispatcher.start(); dispatcher.thread.join(1)
        self.assertEqual(cancelled, [[self.first]])
        session, _, _ = self.make()
        session.cancel_messages([self.first, str(uuid.uuid4())])
        self.assertEqual(session.withdrawn, set())
        session.observe([self.row(session)])
        session.send_reply({'text': 'Already completed', 'reply_to': [self.first]})
        session.cancel_messages([self.first])
        self.assertEqual(session.withdrawn, set(), 'A late cancel cannot rewrite an already delivered result')

    def test_followup_invalidates_pending_approval_without_granting_it(self):
        events = []
        gate = ApprovalGate(lambda kind, **values: events.append((kind, values)), timeout=3)
        dispatcher = ChatInputDispatcher(io.StringIO(''), self.run, lambda _: None)
        gate.control_reader = dispatcher.read_reply
        result = []
        thread = threading.Thread(target=lambda: result.append(gate.ask(
            {'app': 'Fixture', 'kind': 'type', 'text': 'Old text', 'reason': 'Old request'}, {})))
        thread.start()
        deadline = time.monotonic() + 1
        while not events and time.monotonic() < deadline:
            time.sleep(.005)
        self.assertEqual(events[0][0], 'approval')
        old = events[0][1]
        gate.invalidate_pending()
        thread.join(1)
        self.assertFalse(thread.is_alive())
        self.assertEqual(result, [None])
        with dispatcher.condition:
            dispatcher.replies.append(dict(approval_id=old['approval_id'], action_hash=old['action_hash'], decision='approve'))
        self.assertIsNone(dispatcher.read_reply(0, approval_id='fresh-token', action_hash='fresh-hash'))

    def test_task_creation_uses_exact_consumed_source_and_matching_reply(self):
        session, _, gate = self.make()
        session.observe([self.row(session)])
        handlers, events = {}, []
        def emit(kind, **values):
            events.append((kind, values))
            with session.dispatcher.condition:
                session.dispatcher.replies.append({'request_id': values['request_id'], 'status': 'saved_not_started'})
                session.dispatcher.condition.notify_all()
        register_task_creation(lambda name, *args: handlers.update({name: args[-1]}), emit, gate, session.validate_source)
        tool = handlers['create_tasks']
        args = {'tasks': [{'title': 'Saved task', 'instructions': 'Only save this task'}]}
        with self.assertRaises(ValueError):
            tool(args)
        self.assertEqual(tool(dict(args, source_message_id=self.first))['status'], 'saved_not_started')
        self.assertEqual(events[0][1]['source_message_id'], self.first)
        with self.assertRaises(ValueError):
            tool(dict(args, source_message_id=self.second))

    def test_archive_fallback_preserves_original_and_steered_user_rows(self):
        archive = ChatContext(self.directory / 'archive')
        archive.begin(self.run, self.first, 'Original request')
        messages = [{'role': 'user', 'content': 'Original request'},
                    {'role': 'assistant', 'content': 'Partial'},
                    {'role': 'user', 'content': 'Follow-up correction'},
                    {'role': 'assistant', 'content': 'Final'}]
        archive.finish({'messages': messages, 'final_response': 'Final', 'completed': True})
        archive.begin(str(uuid.uuid4()), str(uuid.uuid4()), 'Next turn')
        self.assertEqual(archive.history(), messages)


class RealHermesInterruptSurfaceTests(unittest.TestCase):
    def test_actual_mixin_redirects_model_but_only_steers_during_atomic_tool(self):
        # Import the reviewed local runtime surface, not an AIAgent constructor
        # or provider client. No credentials, network request or plugin is used.
        runtime = str(ROOT / '.runtime/hermes-agent')
        if runtime not in sys.path:
            sys.path.insert(0, runtime)
        from agent.interrupt_control import InterruptControlMixin
        class StandIn(InterruptControlMixin):
            pass
        agent = StandIn()
        agent._pending_redirect_lock = threading.Lock()
        agent._pending_steer_lock = threading.Lock()
        agent._pending_redirect = agent._pending_steer = None
        agent._interrupt_requested = False
        agent._model_request_active = threading.Event()
        agent._execution_thread_id = None
        agent._executing_tools = False
        agent._model_request_active.set()
        self.assertTrue(agent.redirect('A correction'))
        self.assertTrue(agent._interrupt_requested)
        self.assertEqual(agent._drain_pending_redirect(), 'A correction')
        agent._interrupt_requested = False
        agent._executing_tools = True
        self.assertTrue(agent.redirect('Another question while tool runs'))
        self.assertFalse(agent._interrupt_requested, 'A new message must not kill an in-flight atomic action')
        self.assertEqual(agent._drain_pending_steer(), 'Another question while tool runs')


class ContinuousWorkerPipeTests(unittest.TestCase):
    def test_real_worker_protocol_and_checkpoint_with_fake_agent_and_real_stdin_pipe(self):
        import worker
        tools, seen, outputs = {}, {}, []
        first, second, conversation, run = [str(uuid.uuid4()) for _ in range(4)]
        class Registry:
            def register(self, **values):
                tools[values['name']] = values['handler']
        class Agent(FakeAgent):
            def __init__(self, **options):
                super().__init__(redirect=False)
                seen['options'] = options
            def run_conversation(self, prompt, **options):
                seen['system'] = options['system_message']
                deadline = time.monotonic() + 2
                while not self.steered and time.monotonic() < deadline:
                    time.sleep(.005)
                if not self.steered:
                    raise AssertionError('The live stdin message never reached steer')
                rows = options['conversation_history'] + [{'role': 'user', 'content': prompt},
                                                         {'role': 'user', 'content': self.steered[0]}]
                self._flush_messages_to_session_db(rows)
                wrong_date = json.loads(tools['create_tasks']({
                    'source_message_id': second,
                    'tasks': [{'title': 'Wrong historical date', 'instructions': 'Do not save',
                               'due_date': '2026-10-30', 'due_date_evidence': 'October 30, 2026'}]}))
                if 'error' not in wrong_date:
                    raise AssertionError('Only the exact current source may provide deadline evidence')
                seen['task_result'] = json.loads(tools['create_tasks']({
                    'source_message_id': second,
                    'tasks': [{'title': 'Explicit saved task', 'instructions': 'Only save this explicit task.',
                               'due_date': '2026-10-29', 'due_date_evidence': '2026-10-29'}]}))
                for key, text in ((first, '第一件事的简洁回答。'), (second, '已保存你明确要求的新任务。')):
                    result = json.loads(tools['send_chat_reply']({'text': text, 'reply_to': [key]}))
                    if not result.get('delivered'):
                        raise AssertionError(result)
                tools['report_outcome']({'status': 'ready', 'summary': 'Ready'})
                return {'completed': True, 'final_response': 'Do not append this duplicate sign-off.',
                        'messages': rows + [{'role': 'assistant', 'content': 'Already delivered.'}],
                        'current_turn_user_idx': len(options['conversation_history'])}
        registry_module = types.ModuleType('tools.registry'); registry_module.registry = Registry()
        agent_module = types.ModuleType('run_agent'); agent_module.AIAgent = Agent
        original_cwd = Path.cwd()
        read_fd, write_fd = os.pipe()
        source = os.fdopen(read_fd, 'r', encoding='utf-8')
        def write(value):
            os.write(write_fd, (json.dumps(value, ensure_ascii=False) + '\n').encode())
        def emit(kind, **values):
            if worker.ACTIVE_CONTINUOUS is not None:
                values.setdefault('run_id', worker.ACTIVE_CONTINUOUS.run_id)
            outputs.append({'type': kind, **values})
            if kind == 'create_tasks':
                write({'request_id': values['request_id'], 'status': 'saved_not_started',
                       'tasks': [{'id': str(uuid.uuid4()), 'title': 'Explicit saved task'}]})
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / 'config.json').write_text(json.dumps({'api_key': 'fixture-not-a-key',
                'base_url': 'http://127.0.0.1:1', 'model': 'fixture'}))
            request = {'mode': 'chat', 'task_id': conversation, 'run_id': run, 'message_id': first,
                       'prompt': 'First request', 'new': False, 'auto_approve': False,
                       'messages': [{'id': first, 'text': 'First request'}]}
            write(request)
            write({'type': 'chat_message', 'run_id': run,
                   'messages': [{'id': second, 'text': '另外，新建一个任务，2026-10-29 前做完，但不要开始执行。'}]})
            try:
                with patch.dict(sys.modules, {'run_agent': agent_module, 'tools.registry': registry_module}), \
                     patch.dict(os.environ, {'TELOS_DATA_DIR': str(directory)}), patch('sys.stdin', source), \
                     patch.object(worker, 'emit', side_effect=emit), patch('openai.OpenAI') as client, \
                     patch('phone_bridge.prepare_phone_home', return_value=False), \
                     patch('phone_bridge.PhoneBridge.attach', return_value=False), \
                     patch('mac_bridge.MacBridge.action', side_effect=AssertionError('No real app actions in fixture')):
                    worker.main()
                    client.return_value.chat.completions.create.assert_not_called()
                final = outputs[-1]
                self.assertEqual(final['type'], 'done')
                self.assertEqual(final['text'], '')
                self.assertEqual(final['handled_message_ids'], [first, second])
                self.assertEqual(final['consumed_message_ids'], [first, second])
                replies = [value for value in outputs if value['type'] == 'chat_reply']
                self.assertEqual(len(replies), 2)
                self.assertEqual([reply['reply_to'] for reply in replies], [[first], [second]])
                self.assertTrue(all(reply['run_id'] == run for reply in replies))
                creation = next(value for value in outputs if value['type'] == 'create_tasks')
                self.assertEqual(creation['source_message_id'], second)
                self.assertEqual(creation['tasks'][0]['due_date'], '2026-10-29')
                self.assertEqual(len([value for value in outputs if value['type'] == 'create_tasks']), 1,
                                 'Invalid evidence must not reach native persistence')
                self.assertEqual(seen['task_result']['status'], 'saved_not_started')
                saved = json.loads((directory / 'chats' / conversation / 'last-turn.json').read_text())
                self.assertEqual(saved['event'], final)
                journal = json.loads((directory / 'chats' / conversation / 'reply-journal' / (run + '.json')).read_text())
                self.assertEqual(saved['event']['delivered_replies'], journal['replies'])
                self.assertEqual([entry['message_id'] for entry in journal['replies']], [entry['message_id'] for entry in replies])
                self.assertIn('CONTINUOUS CHAT', seen['system'])
            finally:
                os.close(write_fd)
                if worker.ACTIVE_CONTINUOUS is not None:
                    worker.ACTIVE_CONTINUOUS.dispatcher.thread.join(1)
                source.close()
                os.chdir(original_cwd)
                worker.ACTIVE_CHAT = None
                worker.ACTIVE_TURN = None
                worker.ACTIVE_CONTINUOUS = None


if __name__ == '__main__':
    unittest.main()
