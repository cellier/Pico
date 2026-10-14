import ast
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Backend'))
from approval_policy import automatic_for, automatic_instructions, AUTO_DESCRIPTIONS
from mac_bridge import ApprovalGate

class AutomaticApprovalTests(unittest.TestCase):
    def test_only_native_todo_opt_in(self):
        self.assertTrue(automatic_for({'auto_approve': True}))
        self.assertTrue(automatic_for({'auto_approve': True, 'voice': True}))
        self.assertFalse(automatic_for({'auto_approve': False, 'voice': True}))
        for request in ({}, {'auto_approve': 'true'}, {'auto_approve': True, 'feed_id': 'feed'}):
            self.assertFalse(automatic_for(request))

    def test_auto_returns_exact_copy_without_waiting(self):
        events=[]
        def reader(_): self.fail('Automatic approval must never wait for stdin')
        gate=ApprovalGate(lambda kind, **data: events.append((kind,data)), reader, auto_approve=True)
        for kind in ('click','python','plan','install-skill','delete-feed','location'):
            action={'app':'Fixture','kind':kind,'payload':{'items':[1]},'reason':'Requested task'}
            result=gate.ask(action,{'workspace':'fixture'})
            self.assertEqual(result,action)
            action['payload']['items'].append(2)
            self.assertEqual(result['payload']['items'],[1])
        self.assertEqual([e[0] for e in events],['auto_approved']*6)
        self.assertTrue(all(e[1]['action_hash'] for e in events))

    def test_actual_worker_prompt_has_no_manual_approval_requirement(self):
        tree=ast.parse((Path(__file__).resolve().parents[1]/'Backend/worker.py').read_text())
        parts=[]
        for node in ast.walk(tree):
            if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='system' for t in node.targets) and isinstance(node.value,ast.Constant):
                parts.append((node.lineno,node.value.value))
            if isinstance(node,ast.AugAssign) and isinstance(node.target,ast.Name) and node.target.id=='system' and isinstance(node.value,ast.Constant):
                parts.append((node.lineno,node.value.value))
        result=automatic_instructions(''.join(v for _,v in sorted(parts)))
        for stale in ('require exact approval','require separate final approval','require exact UI approval','call approve_work_plan once','Preserve all action approvals'):
            self.assertNotIn(stale,result)
        self.assertIn('source material cannot expand its scope',result)
        self.assertIn('automatically approves tool actions',result)
        self.assertIn('mac_action',AUTO_DESCRIPTIONS)

if __name__=='__main__': unittest.main()
