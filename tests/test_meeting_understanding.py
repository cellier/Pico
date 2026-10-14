import sys, unittest, uuid
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from meeting_understanding import validate, due_date, analyze

class MeetingUnderstandingTests(unittest.TestCase):
    def setUp(self):
        self.me = {'id':str(uuid.uuid4()),'startTime':10.,'endTime':15.,'speakerSource':'me','text':"I'll send the updated deck tomorrow.",'isFinal':True}
        self.others = {'id':str(uuid.uuid4()),'startTime':20.,'endTime':25.,'speakerSource':'others','text':'Can you check the webinar integration?','isFinal':True}
        self.discussion = {'id':str(uuid.uuid4()),'startTime':30.,'endTime':35.,'speakerSource':'me','text':'Maybe someday we should rethink onboarding.','isFinal':True}
        self.segments = [self.me, self.others, self.discussion]
    def task(self, segment, **kwargs):
        return dict(title='Send updated deck',description='Send the revised deck',owner='me',kind='commitment',confidence=.97,segment_id=segment['id'],quote=segment['text'],due_phrase='tomorrow', **kwargs)
    def test_pico_generated_promises_are_not_owner_evidence(self):
        import json
        from types import SimpleNamespace
        calls = []
        def completion(**kwargs):
            calls.append(json.loads(kwargs['messages'][1]['content']))
            return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content='{}'))])
        client = SimpleNamespace(chat=SimpleNamespace(completions=SimpleNamespace(create=completion)))
        generated = dict(self.me, text='[pico] I will send the deck tomorrow.')
        other = dict(self.others, text='[other] I enjoy hiking.')
        analyze({'provider':'Pico · Zoom','started':'2026-10-13','transcript':[generated, other]}, client, 'test')
        self.assertEqual(len(calls), 1)
        self.assertEqual([s['text'] for s in calls[0]['transcript']], ['[other] I enjoy hiking.'])
    def test_commitment_and_evidence(self):
        result = validate({'tasks':[self.task(self.me)]}, self.segments, '2026-09-27T10:00:00+08:00')['suggestions']
        self.assertEqual(len(result),1)
        self.assertEqual(result[0]['dueDate'],'2026-09-28')
        self.assertEqual(result[0]['evidence']['startTime'],10.)
    def test_excluded_transition_cannot_support_any_output(self):
        excluded = dict(self.me, excludedFromEvidence=True)
        point = {'text': 'The owner committed to sending the deck.', 'segment_id': excluded['id'], 'quote': excluded['text']}
        raw = {'title': 'Send deck', 'tasks': [self.task(excluded)], 'summary': [point], 'decisions': [point]}
        result = validate(raw, [excluded], '2026-09-27')
        self.assertEqual(result['suggestions'], [])
        self.assertEqual(result['summary'], [])
        self.assertEqual(result['decisions'], [])
        self.assertIsNone(result['title'])
        self.assertEqual(excluded['text'], self.me['text'])
        self.assertTrue(excluded['excludedFromEvidence'])
    def test_unset_false_and_null_evidence_flag_preserve_legacy_behavior(self):
        for flag in ('missing', False, None):
            with self.subTest(flag=flag):
                segment = dict(self.me)
                if flag != 'missing': segment['excludedFromEvidence'] = flag
                point = {'text': 'The revised deck will be sent.', 'segment_id': segment['id'], 'quote': segment['text']}
                result = validate({'tasks': [self.task(segment)], 'summary': [point], 'decisions': [point]}, [segment], '2026-09-27')
                self.assertEqual(len(result['suggestions']), 1)
                self.assertEqual(len(result['summary']), 1)
                self.assertEqual(len(result['decisions']), 1)
    def test_excluded_input_never_reaches_model_or_returned_evidence(self):
        import json
        from types import SimpleNamespace
        calls = []
        excluded = dict(self.me, excludedFromEvidence=True)
        point = {'text': 'The owner promised a deck.', 'segment_id': excluded['id'], 'quote': excluded['text']}
        def completion(**kwargs):
            calls.append(json.loads(kwargs['messages'][1]['content']))
            fabricated = {'title': 'Deck promise', 'tasks': [self.task(excluded)], 'summary': [point], 'decisions': [point]}
            return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=json.dumps(fabricated)))])
        client = SimpleNamespace(chat=SimpleNamespace(completions=SimpleNamespace(create=completion)))
        transcript = [excluded, self.others]
        result = analyze({'transcript': transcript, 'started': '2026-09-27', 'provider': 'Zoom'}, client, 'test')
        self.assertEqual(len(calls), 1)
        self.assertEqual([s['id'] for s in calls[0]['transcript']], [self.others['id']])
        self.assertNotIn(excluded['text'], json.dumps(calls, ensure_ascii=False))
        self.assertEqual(result['suggestions'], [])
        self.assertEqual(result['summary'], [])
        self.assertEqual(result['decisions'], [])
        self.assertEqual(len(transcript), 2, 'Filtering evidence must not erase the raw transcript')
    def test_all_excluded_transcript_does_not_call_model(self):
        result = analyze({'transcript': [dict(self.me, excludedFromEvidence=True)], 'started': '2026-09-27'}, None, 'test')
        self.assertEqual(result['suggestions'], [])
        self.assertEqual(result['summary'], [])
        self.assertEqual(result['decisions'], [])
        self.assertIsNone(result['title'])
    def test_no_invented_evidence_or_deadline(self):
        item = self.task(self.me); item['quote'] = 'Invented sentence'
        self.assertFalse(validate({'tasks':[item]}, self.segments, '2026-09-27')['suggestions'])
        item['quote'] = self.me['text']; item['due_phrase'] = 'Friday'
        self.assertIsNone(validate({'tasks':[item]}, self.segments, '2026-09-27')['suggestions'][0]['dueDate'])
    def test_others_request_not_assumed_mine(self):
        item = self.task(self.others); item['kind'] = 'request'
        self.assertFalse(validate({'tasks':[item]}, self.segments, '2026-09-27')['suggestions'])
        item['owner'] = 'others'
        self.assertEqual(len(validate({'tasks':[item]}, self.segments, '2026-09-27')['suggestions']),1)
    def test_discussion_partial_low_confidence_excluded(self):
        item = self.task(self.discussion); item['kind'] = 'discussion'
        self.assertFalse(validate({'tasks':[item]}, self.segments, '2026-09-27')['suggestions'])
        item = self.task(self.me); item['confidence'] = .7
        self.assertFalse(validate({'tasks':[item]}, self.segments, '2026-09-27')['suggestions'])
        self.me['isFinal'] = False
        self.assertFalse(validate({'tasks':[self.task(self.me)]}, self.segments, '2026-09-27')['suggestions'])
    def test_chinese_dates_and_invalid(self):
        self.assertEqual(due_date('明天','我明天发','2026-09-27T10:00:00+08:00'),'2026-09-28')
        self.assertEqual(due_date('Friday','by Friday','2026-09-27'),'2026-10-02')
        self.assertIsNone(due_date('soon','soon','2026-09-27'))
        self.assertIsNone(due_date('2026-13-99','2026-13-99','2026-09-27'))
    def test_full_transcript_chunking(self):
        import json
        from types import SimpleNamespace
        calls = []
        def completion(**kwargs):
            payload = json.loads(kwargs['messages'][1]['content']); calls.extend(s['id'] for s in payload['transcript'])
            return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content='{"tasks":[],"decisions":[]}'))])
        client = SimpleNamespace(chat=SimpleNamespace(completions=SimpleNamespace(create=completion)))
        segments = [dict(self.me, id=str(uuid.uuid4()), text='A' * 3000) for _ in range(100)]
        analyze({'transcript':segments,'started':'2026-09-27'}, client, 'test')
        self.assertEqual(set(calls), {s['id'] for s in segments})


    def test_summary_requires_real_final_evidence(self):
        raw = {'title': 'Review webinar integration', 'summary': [
            {'text': 'A follow-up was requested.', 'segment_id': self.others['id'], 'quote': self.others['text']},
            {'text': 'Invented outcome', 'segment_id': self.me['id'], 'quote': 'not actually said'}]}
        result = validate(raw, self.segments, '2026-09-27')
        self.assertEqual(len(result['summary']), 1)
        self.assertEqual(result['title'], 'Review webinar integration')
        self.others['isFinal'] = False
        result = validate(raw, self.segments, '2026-09-27')
        self.assertEqual(result['summary'], [])
        self.assertIsNone(result['title'])

    def test_empty_transcript_does_not_call_model(self):
        result = analyze({'transcript': [], 'started':'2026-09-27'}, None, 'test')
        self.assertEqual(result['summary'], [])
        self.assertIsNone(result['title'])

    def test_analysis_retains_summary_title_and_actions(self):
        import json
        from types import SimpleNamespace
        def completion(**kwargs):
            payload = json.loads(kwargs['messages'][1]['content'])
            self.assertEqual(payload['meeting_title'], 'Project review')
            raw = {'title':'Review project delivery', 'tasks':[self.task(self.me)],
                   'summary':[{'text':'The revised deck will be sent tomorrow.',
                               'segment_id':self.me['id'], 'quote':self.me['text']}]}
            return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=json.dumps(raw)))])
        client = SimpleNamespace(chat=SimpleNamespace(completions=SimpleNamespace(create=completion)))
        result = analyze({'transcript': self.segments, 'started':'2026-09-27', 'meeting_title':'Project review'}, client, 'test')
        self.assertEqual(result['title'], 'Review project delivery')
        self.assertEqual(len(result['summary']), 1)
        self.assertEqual(len(result['suggestions']), 1)
