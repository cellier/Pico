"""Generated-file migration preserves websites, history and isolation."""
import errno
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

BACKEND = Path(__file__).resolve().parents[1] / 'Backend'
sys.path.insert(0, str(BACKEND))
from generated_files import GeneratedFilesError, generated_files_root, task_workspace
from worker import workspace_path


class GeneratedFilesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.data = self.base / 'data'
        self.id = str(uuid.uuid4())
        self.environment = patch.dict(os.environ, {'PICO_FILES_DIR': ''})
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.temp.cleanup()

    def legacy(self, chat=False):
        path = self.data / ('chats' if chat else 'tasks') / self.id / 'files'
        path.mkdir(parents=True)
        return path

    def test_default_user_documents_and_isolated_data_root(self):
        home = self.base / 'home'
        with patch.dict(os.environ, {'HOME': str(home)}):
            data = home / 'Library/Application Support/Telos'
            self.assertEqual(generated_files_root(data), home / 'Documents/Pico')
            self.assertFalse((home / 'Documents/Pico/Tasks').exists())
        self.assertEqual(generated_files_root(self.data), self.data / 'PicoFiles')

    def test_explicit_home_override_is_normalized_and_private(self):
        home = self.base / 'home'
        with patch.dict(os.environ, {'HOME': str(home), 'PICO_FILES_DIR': '~/Exports/../Pico Files'}):
            workspace = task_workspace(self.data, self.id.upper(), chat=True)
        expected = home / 'Pico Files/Chats' / self.id
        self.assertEqual(workspace, expected)
        self.assertTrue((self.data / 'chats' / self.id / 'files').is_symlink())
        for path in [home / 'Pico Files', expected.parent, expected]:
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.data / 'generated-files.lock').stat().st_mode), 0o600)

    def test_full_workspace_rename_keeps_old_paths_assets_and_history(self):
        old = self.legacy()
        (old / 'site/assets').mkdir(parents=True)
        (old / '.presentations/draft').mkdir(parents=True)
        (old / 'site/index.html').write_text('<img src="assets/photo.svg">')
        (old / 'site/assets/photo.svg').write_text('<svg/>')
        (old / '.presentations/draft/manifest.json').write_text('{"draft":true}')
        history = old.parent / 'history.json'
        history.write_text(json.dumps({'path': str(old / 'site/index.html')}))
        history_bytes = history.read_bytes()
        inode = old.stat().st_ino
        result = task_workspace(self.data, self.id)
        self.assertFalse(result.is_symlink())
        self.assertEqual(result.stat().st_ino, inode, 'Migration must rename, not copy')
        self.assertEqual(old.resolve(), result)
        self.assertEqual((old / 'site/index.html').read_text(), '<img src="assets/photo.svg">')
        self.assertEqual((old / 'site/assets/photo.svg').read_text(), '<svg/>')
        self.assertEqual((result / '.presentations/draft/manifest.json').read_text(), '{"draft":true}')
        self.assertEqual(history.read_bytes(), history_bytes)
        self.assertEqual(task_workspace(self.data, self.id), result)

    def test_task_and_chat_workspaces_are_separate_and_reject_escapes(self):
        task = task_workspace(self.data, self.id)
        chat = task_workspace(self.data, self.id, chat=True)
        self.assertNotEqual(task, chat)
        outside = self.base / 'outside'
        outside.mkdir()
        (task / 'external').symlink_to(outside, target_is_directory=True)
        for name in ['../secret.txt', str(outside / 'secret.txt'), 'external/secret.txt', '.']:
            with self.assertRaises(ValueError):
                workspace_path(task, name)
        self.assertEqual(workspace_path(task, 'site/app.css'), task / 'site/app.css')
        with self.assertRaises(ValueError):
            task_workspace(self.data, '../../unrelated')

    def test_conflicting_populated_trees_are_not_merged_or_overwritten(self):
        old = self.legacy()
        (old / 'same.txt').write_text('original')
        destination = self.data / 'PicoFiles/Tasks' / self.id
        destination.mkdir(parents=True)
        (destination / 'same.txt').write_text('existing destination')
        with self.assertRaises(GeneratedFilesError):
            task_workspace(self.data, self.id)
        self.assertFalse(old.is_symlink())
        self.assertEqual((old / 'same.txt').read_text(), 'original')
        self.assertEqual((destination / 'same.txt').read_text(), 'existing destination')

    def test_empty_destination_and_empty_legacy_are_safe_to_reuse(self):
        old = self.legacy()
        (old / 'keep.txt').write_text('original')
        destination = self.data / 'PicoFiles/Tasks' / self.id
        destination.mkdir(parents=True)
        self.assertEqual(task_workspace(self.data, self.id), destination)
        self.assertEqual((destination / 'keep.txt').read_text(), 'original')

        other = str(uuid.uuid4())
        other_old = self.data / 'tasks' / other / 'files'
        other_old.mkdir(parents=True)
        other_new = self.data / 'PicoFiles/Tasks' / other
        other_new.mkdir()
        (other_new / 'keep.txt').write_text('already migrated')
        self.assertEqual(task_workspace(self.data, other), other_new)
        self.assertTrue(other_old.is_symlink())
        self.assertEqual((other_old / 'keep.txt').read_text(), 'already migrated')

    def test_unknown_legacy_link_and_destination_link_are_rejected(self):
        parent = self.data / 'tasks' / self.id
        parent.mkdir(parents=True)
        outside = self.base / 'outside'
        outside.mkdir()
        old = parent / 'files'
        old.symlink_to(outside)
        with self.assertRaises(GeneratedFilesError):
            task_workspace(self.data, self.id)
        self.assertEqual(old.resolve(), outside)
        old.unlink()
        destination = self.data / 'PicoFiles/Tasks' / self.id
        destination.symlink_to(outside)
        with self.assertRaises(GeneratedFilesError):
            task_workspace(self.data, self.id)
        self.assertTrue(destination.is_symlink())

    def test_cross_volume_error_leaves_original_tree(self):
        old = self.legacy()
        (old / 'keep.txt').write_text('original')
        with patch('generated_files.os.rename', side_effect=OSError(errno.EXDEV, 'Different volume')):
            with self.assertRaisesRegex(GeneratedFilesError, 'different volumes'):
                task_workspace(self.data, self.id)
        self.assertFalse(old.is_symlink())
        self.assertEqual((old / 'keep.txt').read_text(), 'original')
        self.assertFalse((self.data / 'PicoFiles/Tasks' / self.id).exists())

    def test_alias_creation_failure_rolls_back_renamed_directory(self):
        old = self.legacy()
        (old / 'keep.txt').write_text('original')
        with patch('generated_files.Path.symlink_to', side_effect=PermissionError('Denied')):
            with self.assertRaises(PermissionError):
                task_workspace(self.data, self.id)
        self.assertFalse(old.is_symlink())
        self.assertEqual((old / 'keep.txt').read_text(), 'original')
        self.assertFalse((self.data / 'PicoFiles/Tasks' / self.id).exists())

    def test_post_move_permission_failure_restores_original_path(self):
        import generated_files
        old = self.legacy()
        (old / 'keep.txt').write_text('original')
        destination = self.data / 'PicoFiles/Tasks' / self.id
        ensure = generated_files._private_directory
        def fail_final_directory(path):
            if path == destination:
                raise PermissionError('Fixture cannot set workspace permissions')
            ensure(path)
        with patch('generated_files._private_directory', side_effect=fail_final_directory):
            with self.assertRaises(PermissionError):
                task_workspace(self.data, self.id)
        self.assertFalse(old.is_symlink())
        self.assertEqual((old / 'keep.txt').read_text(), 'original')
        self.assertFalse(destination.exists())

    def test_concurrent_workers_serialize_one_migration(self):
        old = self.legacy()
        (old / 'original.txt').write_text('original')
        code = ('import sys;from pathlib import Path;sys.path.insert(0,sys.argv[1]);'
                'from generated_files import task_workspace;'
                'p=task_workspace(sys.argv[2],sys.argv[3]);'
                '(p/(sys.argv[4]+".txt")).write_text(sys.argv[4]);print(p)')
        workers = [subprocess.Popen([sys.executable, '-c', code, str(BACKEND), str(self.data), self.id, str(i)],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                   for i in range(5)]
        expected = self.data / 'PicoFiles/Tasks' / self.id
        for process in workers:
            out, error = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 0, error)
            self.assertEqual(out.strip(), str(expected))
        self.assertEqual(old.resolve(), expected)
        self.assertEqual((old / 'original.txt').read_text(), 'original')
        self.assertEqual(len(list(expected.iterdir())), 6)

    def test_disk_root_and_home_are_not_chmod_targets(self):
        for root in ['/', str(Path.home())]:
            with patch.dict(os.environ, {'PICO_FILES_DIR': root}):
                with self.assertRaises(GeneratedFilesError):
                    generated_files_root(self.data)


if __name__ == '__main__':
    unittest.main()
