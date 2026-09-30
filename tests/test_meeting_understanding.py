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
    def test_commitment_and_evidence(self):
        result = validate({'tasks':[self.task(self.me)]}, self.segments, '2026-09-27T10:00:00+08:00')['suggestions']
        self.assertEqual(len(result),1)
        self.assertEqual(result[0]['dueDate'],'2026-09-28')
        self.assertEqual(result[0]['evidence']['startTime'],10.)
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
