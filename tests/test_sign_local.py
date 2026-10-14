import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

class ExistingSigningOnly(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();(self.root/'scripts').mkdir();(self.root/'bin').mkdir()
        self.script=self.root/'scripts/sign-local.py'
        shutil.copy2(Path(__file__).parents[1]/'scripts/sign-local.py',self.script)
        self.runtime=self.root/'.runtime/local-signing'; self.runtime.mkdir(parents=True)
        for name in ['Telos.keychain-db','certificate.pem']:(self.runtime/name).write_text('fixture')
        (self.runtime/'keychain-password').write_text('fixture-credential')
        self.log=self.root/'calls'
        helper='''#!/usr/bin/env python3
import os,sys,json
from pathlib import Path
with open(os.environ['SIGN_TEST_LOG'],'a') as f:f.write(json.dumps([Path(sys.argv[0]).name]+sys.argv[1:])+'\\n')
if sys.argv[1:3]==['list-keychains','-d'] and os.environ.get('REGISTERED')=='1':print(json.dumps(os.environ['SIGN_TEST_KEYCHAIN']))
if Path(sys.argv[0]).name=='openssl':print('sha1 Fingerprint=12:34')
'''
        for name in ['security','openssl','codesign']:
            p=self.root/'bin'/name;p.write_text(helper);p.chmod(0o700)
        self.env={**os.environ,'PATH':str(self.root/'bin')+':'+os.environ['PATH'],'SIGN_TEST_LOG':str(self.log),'SIGN_TEST_KEYCHAIN':str(self.runtime/'Telos.keychain-db'),'REGISTERED':'1'}
        self.env.pop('TELOS_CODESIGN_IDENTITY',None)
    def run_script(self):return subprocess.run(['python3',str(self.script),str(self.root/'App.app')],env=self.env,capture_output=True,text=True)
    def test_existing_identity_does_not_create_import_or_register(self):
        p=self.run_script();self.assertEqual(p.returncode,0,p.stderr)
        calls=[json.loads(x) for x in self.log.read_text().splitlines()]
        self.assertTrue(any(x[0]=='codesign' for x in calls))
        forbidden={'create-keychain','import','set-key-partition-list','delete-keychain','add-trusted-cert'}
        self.assertFalse(any(any(v in forbidden for v in x) for x in calls))
        self.assertFalse(any(x[0]=='security' and x[1]=='list-keychains' and '-s' in x for x in calls))
    def test_missing_configuration_fails_without_bootstrap(self):
        shutil.rmtree(self.runtime);p=self.run_script();self.assertNotEqual(p.returncode,0);self.assertFalse(self.runtime.exists());self.assertFalse(self.log.exists())
    def test_unregistered_keychain_fails_without_mutation(self):
        self.env['REGISTERED']='0';p=self.run_script();self.assertNotEqual(p.returncode,0)
        calls=[json.loads(x) for x in self.log.read_text().splitlines()];self.assertEqual(len(calls),1)
    def test_invalid_active_path_fails(self):
        (self.runtime/'active-keychain.json').write_text(json.dumps({'keychain':'../unexpected','password_file':'keychain-password'}))
        self.assertNotEqual(self.run_script().returncode,0);self.assertFalse(self.log.exists())
if __name__=='__main__':unittest.main()
