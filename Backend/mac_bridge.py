"""Telos's execution boundary around macOS Harness.

The native launcher chooses automatic or interactive approval.
Both modes preserve exact payloads, target validation and execution audit records.
"""
import base64
import copy
import math
import signal
import shutil
import fcntl
import hashlib
import json
import os
import select
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

SAFE_KEYS = frozenset({'cmd+f', 'escape', 'esc', 'tab', 'shift+tab', 'pageup', 'pagedown', 'home', 'end'})
ACTIONS = frozenset({'key', 'type', 'click', 'ax_press', 'ax_set', 'scroll', 'applescript', 'python'})

def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':'))

def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()

def needs_approval(action):
    """Never trust a model-supplied risk/safe flag, summary, or script comment."""
    kind = action.get('kind')
    if kind not in ACTIONS:
        raise ValueError('Unsupported Mac action')
    if kind == 'key' and action.get('key', '').lower() in SAFE_KEYS:
        return False
    if kind == 'scroll':
        return False
    return True

def state_fingerprint(state):
    # Ignore focus changes caused by clicking the approval UI, not target contents.
    nodes = [{k:v for k,v in n.items() if k not in {'focused', 'element_index'}} for n in state.get('nodes', [])]
    return digest({'app':state.get('app'), 'nodes':nodes, 'windows':state.get('windows')})

class ApprovalGate:
    def __init__(self, emit, reader=None, timeout=300, auto_approve=False):
        self.emit = emit
        self.auto_approve = auto_approve is True
        self.reader = reader or self._read
        self.timeout = timeout
        self.lock = threading.Lock()
    def _read(self, timeout):
        ready, _, _ = select.select([sys.stdin], [], [], timeout)
        if not ready: return None
        line = sys.stdin.readline()
        return json.loads(line) if line else None
    def ask(self, action, context):
        # Deep copy binds execution to the immutable reviewed payload, not mutable args.
        exact = copy.deepcopy(action)
        if self.auto_approve:
            self.emit('auto_approved', action_hash=digest({'action':exact, 'context':context}),
                      app=exact.get('app', 'Task'), text=exact.get('reason', 'Task action'))
            return exact
        approval_id = str(uuid.uuid4())
        token = digest({'action':exact, 'context':context})
        end = time.time() + self.timeout
        with self.lock:
            self.emit('approval', approval_id=approval_id, action_hash=token,
                      app=exact['app'], text=exact.get('reason', 'Confirm this Mac action'),
                      details=json.dumps(exact, ensure_ascii=False, indent=2),
                      risk='plan' if exact['kind']=='plan' else ('script' if exact['kind'] in {'python','applescript'} else 'action'),
                      expires_at=end, screenshot_path=context.get('screenshot_path'))
            try:
                while time.time() < end:
                    reply = self.reader(max(0, end-time.time()))
                    if reply is None: return None
                    if reply.get('approval_id') != approval_id or reply.get('action_hash') != token:
                        continue
                    if reply.get('decision') == 'approve' and time.time() < end: return exact
                    return None
                return None
            finally:
                self.emit('approval_resolved', approval_id=approval_id)

class MacBridge:
    def __init__(self, data_dir, task_dir, emit, gate=None, mac=None):
        self.data_dir = Path(data_dir)
        self.task_dir = Path(task_dir)
        self.emit = emit
        self.gate = gate or ApprovalGate(emit)
        self._mac = mac
        self.observation = None
        self.lock = threading.RLock()
        self.denied = set()
        self.approved_steps = []
        self.plan_expires = 0
        self.audit_path = self.task_dir / 'mac-actions.jsonl'
    @property
    def mac(self):
        if self._mac is None:
            from macos_harness.macos import MacOS
            self._mac = MacOS()
        return self._mac
    def audit(self, event, **data):
        self.task_dir.mkdir(parents=True, exist_ok=True)
        with self.audit_path.open('a') as f:
            f.write(json.dumps({'time':time.time(), 'event':event, **data},ensure_ascii=False)+'\n')
        self.audit_path.chmod(0o600)
    def apps(self, _args=None):
        return {'apps':self.mac.list_apps(), 'permissions':self.mac.permissions()}
    def open_app(self, args):
        bundle=args['bundle_id']
        if bundle=='com.telos.mac' or not isinstance(bundle,str) or not __import__('re').fullmatch(r'[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+',bundle):
            raise ValueError('Use an installed application bundle ID, not a URL or command.')
        from AppKit import NSWorkspace
        url=NSWorkspace.sharedWorkspace().URLForApplicationWithBundleIdentifier_(bundle)
        if url is None: raise ValueError('This app is not installed. Ask the user; do not install software automatically.')
        result=subprocess.run(['/usr/bin/open','-g','-b',bundle],capture_output=True,text=True,timeout=15)
        if result.returncode: raise RuntimeError(result.stderr[:500])
        self.audit('app_opened',bundle_id=bundle)
        return {'opened':bundle,'next':'Use mac_apps and mac_observe to inspect the running app.'}
    def resolve(self, query):
        # Require exact identity; do not guess recipients/apps using loose substrings.
        matches=[a for a in self.mac.list_apps() if str(query).casefold() in
                 {str(a.get(k,'')).casefold() for k in ('name','bundle_id','pid','path')}]
        if len(matches) != 1: raise ValueError('App identity is missing or ambiguous. Use a PID from mac_apps.')
        app=matches[0]
        if app.get('bundle_id') == 'com.telos.mac':
            raise ValueError('The agent cannot operate its own approval interface. Ask the user directly.')
        return app
    def snapshot(self, app):
        return self.mac.get_app_state(str(app['pid']), max_depth=16, max_nodes=600, include_menu_bar=False)
    def observe(self, args):
        with self.lock:
            app=self.resolve(args['app'])
            state=self.snapshot(app)
            observation_id=str(uuid.uuid4())
            shot=None
            if args.get('screenshot',False):
                shot=self.mac.see(str(app['pid']),max_width=1280,max_height=1000,show_pointer=False)
            self.observation={'id':observation_id,'app':app,'state':state,'fingerprint':state_fingerprint(state),
                              'at':time.time(),'screenshot':shot}
            # Window text is untrusted. No values from it are interpreted as authorization.
            result={'observation_id':observation_id,'app':app,'text':state.get('text','')[:24000],
                    'windows':state.get('windows'), 'untrusted':True}
            if shot:
                folder=self.task_dir/'mac-snapshots';folder.mkdir(parents=True,exist_ok=True)
                original=Path(shot['path']);saved=folder/(observation_id+'.png')
                shutil.move(str(original),str(saved));saved.chmod(0o600)
                shot['path']=str(saved)
                # Keep a bounded local review trail, in the private task directory.
                for old in sorted(folder.glob('*.png'),key=lambda p:p.stat().st_mtime)[:-10]:old.unlink()
                result['screenshot']=shot
            return result
    @staticmethod
    def plan_signature(action):
        # Observation IDs and explanation text may change, but executable parameters cannot.
        return digest({k:v for k,v in action.items() if k not in {'reason','observation_id'}})
    def approve_plan(self, args):
        with self.lock:
            return self._approve_plan(args)
    def _approve_plan(self, args):
        steps=args.get('steps',[])
        if not isinstance(steps,list) or not 1 <= len(steps) <= 24:
            raise ValueError('A work plan must contain 1–24 exact steps.')
        exact_steps=[]
        for raw in steps:
            step=copy.deepcopy(raw)
            needs_approval(step)
            app=self.resolve(step['app'])
            step['app']=app['name']; step['pid']=app['pid']
            step.pop('observation_id',None)
            if step['kind'] in {'python','applescript'} and not step.get('source','').strip():
                raise ValueError('Include complete script source in the plan.')
            exact_steps.append(step)
        self.approved_steps=[]; self.plan_expires=0
        review={'app':', '.join(dict.fromkeys(s['app'] for s in exact_steps)),
                'kind':'plan','reason':args['reason'], 'steps':exact_steps,
                'scope':'Only these exact steps, once each, during this task run. New or changed operations require confirmation.'}
        approved=self.gate.ask(review,{'task':str(self.task_dir)})
        if approved is None:
            self.denied.update(self.plan_signature(step) for step in exact_steps)
            self.audit('plan_denied',steps=len(exact_steps))
            return {'status':'denied','message':'User declined the plan. Stop; do not resubmit it as individual actions.'}
        self.approved_steps=[self.plan_signature(step) for step in approved['steps']]
        self.plan_expires=time.time()+1800
        self.audit('plan_approved',steps=len(self.approved_steps),expires=self.plan_expires)
        return {'status':'approved','steps':len(self.approved_steps),
                'next':('Execute the steps with mac_action and verify each result. Further requested actions are automatically approved.' if self.gate.auto_approve else 'Execute these exact steps with mac_action, observing before each one. Do not request approval again for unchanged steps. Changed or additional steps need approval.')}
    def consume_plan_step(self, action):
        if time.time() >= self.plan_expires:
            self.approved_steps=[]
            return False
        signature=self.plan_signature(action)
        if signature not in self.approved_steps: return False
        self.approved_steps.remove(signature)
        self.audit('plan_step_authorized',action_hash=signature,remaining=len(self.approved_steps))
        return True
    def action(self, raw):
        with self.lock:
            action=copy.deepcopy(raw)
            required=needs_approval(action)
            signature=digest({k:v for k,v in action.items() if k not in {'reason','observation_id'}})
            if signature in self.denied:
                return {'status':'denied','message':'This action was already declined during this turn. Stop and ask the user.'}
            app=self.resolve(action['app'])
            previous=self.observation
            if not previous or previous['app']['pid'] != app['pid'] or action.get('observation_id') != previous['id']:
                raise ValueError('Observe this app first and provide its current observation_id.')
            if time.time()-previous['at']>180:
                raise ValueError('Observation expired. Observe the app again before acting.')
            action['app']=app['name']
            action['pid']=app['pid']
            if action['kind'] in {'applescript','python'} and not action.get('source','').strip():
                raise ValueError('Script source is required.')
            if action['kind'] in {'type','ax_set'} and not isinstance(action.get('text'),str):
                raise ValueError('Text is required.')
            if action['kind']=='click':
                shot=previous['screenshot']
                if not shot: raise ValueError('Coordinate actions require a preceding screenshot observation.')
                for key,limit in [('x',shot['width']),('y',shot['height'])]:
                    value=float(action[key])
                    if not math.isfinite(value) or not 0<=value<limit: raise ValueError('Coordinates must be inside the observed app screenshot.')
            context={'pid':app['pid'],'state':previous['fingerprint'],'screenshot_path':(previous['screenshot'] or {}).get('path')}
            if self.plan_signature(action) in self.denied:
                return {'status':'denied','message':'User declined this planned action. Stop.'}
            planned = required and self.consume_plan_step(action)
            if required and not planned:
                self.audit('requested', action=action, context=context)
                approved=self.gate.ask(action,context)
                if approved is None:
                    self.denied.add(signature)
                    self.audit('denied_or_expired',action_hash=digest(action))
                    return {'status':'denied','message':'User denied, cancelled, or approval expired. Do not retry this action without a new user request.'}
                action=approved
            # Global lock serializes writes across tasks; a waiting approval holds no desktop lock.
            lock_path=self.data_dir/'mac-execution.lock'
            with lock_path.open('a') as lock_file:
                try: fcntl.flock(lock_file,fcntl.LOCK_EX|fcntl.LOCK_NB)
                except BlockingIOError:
                    return {'status':'busy','message':'Another task is using the Mac. Observe again when it finishes.'}
                current=self.snapshot(app)
                if state_fingerprint(current) != previous['fingerprint']:
                    self.audit('stale',action_hash=digest(action))
                    self.observation=None
                    return {'status':'stale','message':'The target app changed. Nothing was executed. Observe and request fresh approval.'}
                # snapshot resets the last screenshot; restore the exact reviewed coordinate map.
                if previous['screenshot']:
                    self.mac._last_screenshot=previous['screenshot']
                self.audit('executing',action=action,approved=required)
                try:
                    result=self.execute(action)
                except Exception as e:
                    self.observation=None
                    self.audit('failed',error=str(e)[:300])
                    raise RuntimeError('Mac action failed or was interrupted; it may have partially acted. Observe the actual state before continuing. '+str(e)) from e
                self.observation=None
                self.audit('executed',action_hash=digest(action))
                return {'status':'executed','result':result,'next':'Observe the target app to verify the actual outcome; do not assume success.'}
    def execute(self, a):
        app=str(a['pid']); kind=a['kind']
        if kind=='key': return self.mac.key(a['key'],app=app)
        if kind=='type': return self.mac.type(a['text'],app=app)
        if kind=='click': return self.mac.click(float(a['x']),float(a['y']),app=app,coordinate_space='screenshot',clicks=1)
        if kind=='ax_press': return self.mac.ax.perform(int(a['element_index']),'AXPress')
        if kind=='ax_set': return self.mac.ax.set(int(a['element_index']),'AXValue',a['text'])
        if kind=='scroll': return self.mac.scroll(int(a.get('delta_y',-3)),app=app)
        if kind in {'applescript','python'}:
            # Never exec model source inside the trusted worker or approval gate.
            code = a['source'] if kind=='python' else 'print(mac.script('+repr(a['source'])+'))'
            env={k:v for k,v in os.environ.items() if not any(word in k.upper() for word in ('KEY','TOKEN','SECRET','PASSWORD'))}
            env.update(MACOS_HARNESS_TELEMETRY='0',ANONYMIZED_TELEMETRY='false',DO_NOT_TRACK='1')
            process=subprocess.Popen([sys.executable,'-m','macos_harness.cli'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,
                                     cwd=self.task_dir/'files',env=env,start_new_session=True)
            try: output,error=process.communicate(code,timeout=60)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid,signal.SIGTERM)
                process.communicate(timeout=5)
                raise RuntimeError('Script timed out and was stopped. Inspect its partial effects before continuing.')
            if process.returncode: raise RuntimeError((error or output)[-2000:])
            return output[-12000:]
        raise ValueError('Unsupported action')

if __name__=='__main__':
    from macos_harness.macos import MacOS
    print(json.dumps(MacOS().doctor(),ensure_ascii=False))
