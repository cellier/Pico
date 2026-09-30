import copy
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Backend'))
from mac_bridge import ApprovalGate, MacBridge, needs_approval

class PolicyTests(unittest.TestCase):
    def test_no_model_risk_override(self):
        for a in [
            {'kind':'python','source':'# safe\nprint(1)'}, {'kind':'applescript','source':'get volume settings'},
            {'kind':'click','x':1,'y':1},{'kind':'key','key':'cmd+return'}, {'kind':'key','key':'return'},
            {'kind':'key','key':'cmd+delete'},{'kind':'type','text':'hello\n'}, {'kind':'ax_press'}, {'kind':'ax_set'}]:
            self.assertTrue(needs_approval(dict(a,safe=True,risk='low',reason='Only read')))
        self.assertFalse(needs_approval({'kind':'key','key':'cmd+f'}))
        with self.assertRaises(ValueError): needs_approval({'kind':'shell'})

class GateTests(unittest.TestCase):
    def test_exact_once_and_wrong_id_rejected(self):
        events=[]; replies=[]
        def emit(kind,**data):
            events.append((kind,data))
            if kind=='approval':
                replies.extend([{'approval_id':'wrong','action_hash':data['action_hash'],'decision':'approve'},
                                {'approval_id':data['approval_id'],'action_hash':data['action_hash'],'decision':'approve'}])
        gate=ApprovalGate(emit,lambda _: replies.pop(0) if replies else None)
        action={'app':'Fixture','kind':'key','key':'return'}
        self.assertEqual(gate.ask(action,{}),action)
        self.assertEqual([e[0] for e in events],['approval','approval_resolved'])
    def test_denial_eof_and_timeout_fail_closed(self):
        for mode in ['deny','eof','expire']:
            pending={}
            def emit(kind,**data):
                if kind=='approval':pending.update(data)
            def reply(_):
                if mode=='eof': return None
                if mode=='expire': time.sleep(0.03)
                return {'approval_id':pending['approval_id'],'action_hash':pending['action_hash'],'decision':'deny' if mode=='deny' else 'approve'}
            self.assertIsNone(ApprovalGate(emit,reply,timeout=0.01 if mode=='expire' else 2).ask({'app':'Fixture','kind':'type'},{}))
    def test_payload_mutation_does_not_change_approved_action(self):
        action={'app':'Fixture','kind':'type','text':'original'}; pending={}
        def emit(kind,**data):
            if kind=='approval':pending.update(data);action['text']='changed'
        def reply(_):return {'approval_id':pending['approval_id'],'action_hash':pending['action_hash'],'decision':'approve'}
        self.assertEqual(ApprovalGate(emit,reply).ask(action,{})['text'],'original')
    def test_replayed_approval_does_not_authorize_new_request(self):
        last={}; old={}
        def emit(kind,**data):
            if kind=='approval':last.update(data)
        def first(_):
            old.update(approval_id=last['approval_id'],action_hash=last['action_hash'],decision='approve');return dict(old)
        gate=ApprovalGate(emit,first)
        self.assertIsNotNone(gate.ask({'app':'Fixture','kind':'type'},{}))
        replies=[old,None];gate.reader=lambda _:replies.pop(0)
        self.assertIsNone(gate.ask({'app':'Fixture','kind':'type'},{}))

class FakeMac:
    def __init__(self):
        self.content='Hello';self.calls=[]
    def list_apps(self):return [{'name':'Fixture','pid':55,'bundle_id':'com.telos.fixture','path':'/test/Fixture.app'}, {'name':'Telos','pid':56,'bundle_id':'com.telos.mac'}]
    def get_app_state(self,*args,**kwargs):return {'app':self.list_apps()[0], 'nodes':[{'element_index':1,'role':'AXButton','title':self.content}], 'windows':[], 'text':self.content}
    def key(self,*args,**kwargs):self.calls.append((args,kwargs))
    def permissions(self):return {}
class ActionTests(unittest.TestCase):
    def setup_bridge(self,d,decision,mutate=False):
        events=[];pending={}; mac=FakeMac()
        def emit(kind,**data):
            events.append(kind)
            if kind=='approval':pending.update(data)
        def reply(_):
            if mutate:mac.content='Different target'
            return {'approval_id':pending['approval_id'],'action_hash':pending['action_hash'],'decision':decision}
        bridge=MacBridge(d,d,emit,ApprovalGate(emit,reply),mac)
        obs=bridge.observe({'app':'Fixture'})
        action={'app':'Fixture','kind':'key','key':'return','observation_id':obs['observation_id'],'reason':'Press return in fixture'}
        return bridge,mac,action,events
    def test_denied_action_never_executes(self):
        with tempfile.TemporaryDirectory() as d:
            bridge,mac,a,events=self.setup_bridge(d,'deny')
            self.assertEqual(bridge.action(a)['status'],'denied');self.assertEqual(mac.calls,[])
            a['reason']='Try again'
            self.assertEqual(bridge.action(a)['status'],'denied');self.assertEqual(events.count('approval'),1)
    def test_stale_state_never_executes(self):
        with tempfile.TemporaryDirectory() as d:
            bridge,mac,a,_=self.setup_bridge(d,'approve',True)
            self.assertEqual(bridge.action(a)['status'],'stale');self.assertEqual(mac.calls,[])
    def test_approved_exact_target_executes_once(self):
        with tempfile.TemporaryDirectory() as d:
            bridge,mac,a,_=self.setup_bridge(d,'approve')
            self.assertEqual(bridge.action(a)['status'],'executed');self.assertEqual(len(mac.calls),1)
            self.assertEqual(mac.calls[0][1]['app'],'55')
            with self.assertRaises(ValueError):bridge.action(a)
    def test_agent_cannot_operate_approval_ui(self):
        with tempfile.TemporaryDirectory() as d:
            bridge,_,_,_=self.setup_bridge(d,'approve')
            with self.assertRaises(ValueError):bridge.observe({'app':'Telos'})
    def test_missing_observation_blocks_action(self):
        with tempfile.TemporaryDirectory() as d:
            bridge,mac,a,_=self.setup_bridge(d,'approve');a['observation_id']='fake'
            with self.assertRaises(ValueError):bridge.action(a)
            self.assertEqual(mac.calls,[])

class PlanTests(unittest.TestCase):
    def test_two_steps_only_one_confirmation_then_exhausted(self):
        with tempfile.TemporaryDirectory() as d:
            bridge,mac,a,events=ActionTests().setup_bridge(d,'approve')
            second=dict(a,key='cmd+a')
            result=bridge.approve_plan({'reason':'Prepare fixture', 'steps':[a,second]})
            self.assertEqual(result['status'],'approved')
            for step in [a,second]:
                step['observation_id']=bridge.observe({'app':'Fixture'})['observation_id']
                self.assertEqual(bridge.action(step)['status'],'executed')
            self.assertEqual(events.count('approval'),1)
            self.assertEqual(len(mac.calls),2)
            a['observation_id']=bridge.observe({'app':'Fixture'})['observation_id']
            bridge.action(a)
            self.assertEqual(events.count('approval'),2)
    def test_changed_operation_and_expired_plan_need_confirmation(self):
        for expired in [False,True]:
            with tempfile.TemporaryDirectory() as d:
                bridge,mac,a,events=ActionTests().setup_bridge(d,'approve')
                bridge.approve_plan({'reason':'Prepare fixture','steps':[a]})
                if expired: bridge.plan_expires=0
                else: a['key']='cmd+delete'
                a['observation_id']=bridge.observe({'app':'Fixture'})['observation_id']
                bridge.action(a)
                self.assertEqual(events.count('approval'),2)
    def test_plan_denial_cannot_be_retried_as_single_action(self):
        with tempfile.TemporaryDirectory() as d:
            bridge,mac,a,events=ActionTests().setup_bridge(d,'deny')
            self.assertEqual(bridge.approve_plan({'reason':'Prepare fixture','steps':[a]})['status'],'denied')
            a['observation_id']=bridge.observe({'app':'Fixture'})['observation_id']
            self.assertEqual(bridge.action(a)['status'],'denied')
            self.assertEqual(events.count('approval'),1)
            self.assertEqual(mac.calls,[])
    def test_plan_still_requires_fresh_observation(self):
        with tempfile.TemporaryDirectory() as d:
            bridge,mac,a,events=ActionTests().setup_bridge(d,'approve')
            bridge.approve_plan({'reason':'Prepare fixture','steps':[a]})
            mac.content='New target'
            self.assertEqual(bridge.action(a)['status'],'stale')
            self.assertEqual(mac.calls,[])

if __name__=='__main__':unittest.main()
