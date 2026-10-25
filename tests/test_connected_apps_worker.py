"""Exercise the actual worker's connection guard and registration factory.

Only the two self-contained AST blocks are executed: no model/network/runtime
startup is needed, and changing the worker guard changes this test's behavior.
"""
import ast
from pathlib import Path
import sys
import tempfile
import types
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Backend'))
from register_connected_apps import APP_INSTRUCTIONS
from phone_bridge import PhoneBridge


def worker_main():
    parsed = ast.parse((ROOT / 'Backend/worker.py').read_text())
    return next(node for node in parsed.body if isinstance(node, ast.FunctionDef) and node.name == 'main')


def guarded_import(symbol):
    blocks = [node for node in worker_main().body if isinstance(node, ast.If)
              and any(isinstance(item, ast.ImportFrom) and item.module == 'register_connected_apps'
                      and any(alias.name == symbol for alias in item.names) for item in ast.walk(node))]
    if len(blocks) != 1:
        raise AssertionError(f'Expected one worker guard around {symbol}, found {len(blocks)}')
    return compile(ast.fix_missing_locations(ast.Module(body=blocks, type_ignores=[])),
                   str(ROOT / 'Backend/worker.py'), 'exec')


class ConnectedAppsWorkerTests(unittest.TestCase):
    def registration(self, request):
        captured = {}
        def register(name, description, properties, required, handler):
            captured[name] = {'description': description, 'properties': properties,
                              'required': required, 'handler': handler}
        with tempfile.TemporaryDirectory() as folder:
            scope = {'request': request, 'register': register,
                     'string': lambda description: {'type': 'string', 'description': description},
                     'data': Path(folder), 'workspace': Path(folder), 'mac': types.SimpleNamespace(gate=None)}
            exec(guarded_import('register_connected_apps'), scope)
        return captured

    def instructions(self, request):
        scope = {'request': request, 'system': 'Existing Pico instructions.'}
        exec(guarded_import('APP_INSTRUCTIONS'), scope)
        return scope['system']

    def test_user_turn_registers_exact_six_guarded_tools(self):
        tools = self.registration({'mode': 'chat'})
        self.assertEqual(set(tools), {'apps_status', 'apps_connect', 'apps_search',
                                     'apps_schema', 'apps_read', 'apps_write'})
        # These are actual bound production methods, not parallel fake handlers.
        self.assertEqual(tools['apps_write']['handler'].__self__.__class__.__name__, 'AppOperations')
        self.assertEqual(tools['apps_read']['handler'].__self__.__class__.__name__, 'AppOperations')
        self.assertEqual(tools['apps_connect']['handler'].__self__.__class__.__name__, 'AppOperations')
        self.assertIn('operation_id', tools['apps_write']['required'])

    def test_feed_turn_never_registers_account_tools(self):
        self.assertEqual(self.registration({'feed_id': 'private-feed-refresh'}), {})

    def test_only_user_turn_receives_current_connection_instructions(self):
        self.assertIn(APP_INSTRUCTIONS, self.instructions({'mode': 'chat'}))
        self.assertNotIn(APP_INSTRUCTIONS, self.instructions({'feed_id': 'private-feed-refresh'}))

    def test_real_agent_toolset_expression_cannot_bypass_pico_gate(self):
        agent_call = next(node for node in ast.walk(worker_main()) if isinstance(node, ast.Call)
                          and isinstance(node.func, ast.Name) and node.func.id == 'AIAgent')
        expression = next(keyword.value for keyword in agent_call.keywords if keyword.arg == 'enabled_toolsets')
        code = compile(ast.fix_missing_locations(ast.Expression(expression)), '<worker agent toolsets>', 'eval')
        for enabled in (False, True):
            phone = object.__new__(PhoneBridge)
            phone.enabled = enabled
            for feed in (False, True):
                result = eval(code, {'phone': phone, 'request': {'feed_id': 'feed'} if feed else {}})
                self.assertNotIn('connections', result)
                self.assertNotIn('hermes-cli', result)
                self.assertFalse(any(name.startswith('mcp-') for name in result))
                if feed:
                    self.assertEqual(result, ['telos'])


if __name__ == '__main__':
    unittest.main()
