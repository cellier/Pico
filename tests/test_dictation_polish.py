import io,json,sys,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Backend'))
from dictation_polish import polish
class PolishTests(unittest.TestCase):
    config={'base_url':'https://example.test/v1','model':'test','api_key':'fake-test-key'}
    def response(self,text,reason='stop'):
        return {'choices':[{'message':{'content':text},'finish_reason':reason}]}
    def test_timeout_preserves_original(self):
        with patch('dictation_polish.request_json',side_effect=TimeoutError):
            self.assertEqual(polish('不要取消明天四点的会',self.config),('不要取消明天四点的会',False))
    def test_edited_response(self):
        with patch('dictation_polish.request_json',return_value=self.response('明天四点 review Zoom Slides。')) as call:
            self.assertEqual(polish('嗯明天四点 review Zoom Slides',self.config),('明天四点 review Zoom Slides。',True))
            body=call.call_args.args[1]
            self.assertNotIn('tools',body)
            self.assertEqual(json.loads(body['messages'][1]['content'])['transcript'],'嗯明天四点 review Zoom Slides')
    def test_truncated_or_expanded_output_is_rejected(self):
        for text,reason in [('half a','length'),('Invented facts '*100,'stop'),('','stop')]:
            with patch('dictation_polish.request_json',return_value=self.response(text,reason)):
                self.assertEqual(polish('原文',self.config),('原文',False))
    def test_no_request_for_silence(self):
        with patch('dictation_polish.request_json') as call:
            self.assertEqual(polish('',self.config),('',False));call.assert_not_called()

class ConnectionTests(unittest.TestCase):
    def tearDown(self):
        import dictation_polish as module
        module._connection = None; module._connection_origin = None
    def test_reuses_connection_and_discards_failure(self):
        import dictation_polish as module
        from unittest.mock import MagicMock
        self.tearDown()
        conn=MagicMock(); response=conn.getresponse.return_value
        response.status=200; response.read.return_value=b'{"choices": []}'
        with patch('dictation_polish.urllib.request.getproxies',return_value={}), patch('dictation_polish.http.client.HTTPSConnection',return_value=conn) as factory:
            for _ in range(2): module.request_json('https://example.test/v1/chat/completions',{},'fake')
            factory.assert_called_once_with('example.test',None,timeout=3.5)
            self.assertEqual(conn.request.call_count,2)
            conn.request.side_effect=TimeoutError
            with self.assertRaises(TimeoutError): module.request_json('https://example.test/v1/chat/completions',{},'fake')
            self.assertIsNone(module._connection)
            conn.close.assert_called_once()
