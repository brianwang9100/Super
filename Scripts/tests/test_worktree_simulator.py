"""Exercise ownership with real Git worktrees and a strict simulated simctl."""

import fcntl
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

SCRIPT = Path(__file__).resolve().parents[1] / 'worktree_simulator.py'
spec = importlib.util.spec_from_file_location('worktree_simulator', SCRIPT)
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-26-4'
MODEL = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'
PIN = '''xcode-version: "26.4.1"
xcrun simctl list devices --json "iOS 26.4"
RUNTIME_BUILD="23E254a"
device.get("name") == "iPhone 17"
'''


class FakeHost:
    def __init__(self):
        self.devices = {}
        self.mutations = []
        self.fail = None
        self.inventory = None
        self.on_shutdown = lambda: None
        self.build = '23E254a'

    def run(self, args):
        if args[0] == 'git':
            return lifecycle.command(args)
        if args == ['xcodebuild', '-version']:
            return 'Xcode 26.4.1\nBuild version 17E202'
        if args[:3] != ['xcrun', 'simctl', 'list']:
            action = args[2]
            self.mutations.append(args[2:])
            if action == self.fail:
                raise subprocess.CalledProcessError(1, args)
            if action == 'create':
                sid = str(uuid.uuid4()).upper()
                self.devices[sid] = {'udid': sid, 'name': args[3],
                    'deviceTypeIdentifier': args[4], 'state': 'Shutdown', 'isAvailable': True}
                return sid
            if action == 'shutdown':
                self.devices[args[3]]['state'] = 'Shutdown'
                self.on_shutdown()
                return ''
            if action == 'delete':
                del self.devices[args[3]]
                return ''
            raise AssertionError(args)
        if args[3] == 'devices':
            return self.inventory if self.inventory is not None else json.dumps({'devices': {RUNTIME: list(self.devices.values())}})
        if args[3] == 'runtimes':
            return json.dumps({'runtimes': [{'identifier': RUNTIME, 'version': '26.4.1',
                'buildversion': self.build, 'isAvailable': True}]})
        if args[3] == 'devicetypes':
            return json.dumps({'devicetypes': [{'name': 'iPhone 17', 'identifier': MODEL}]})
        raise AssertionError(args)


class WorktreeSimulatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.git('init', '-q')
        workflow = self.repo / '.github/workflows/ios-build.yml'
        workflow.parent.mkdir(parents=True)
        workflow.write_text(PIN)
        self.git('add', '.')
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.test',
                 '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null',
                 'commit', '-qm', 'fixture')
        self.worktree = self.root / 'worktree'
        self.git('worktree', 'add', '--detach', str(self.worktree))
        self.host = FakeHost()
        self.manager = lifecycle.Simulators(self.worktree, self.host.run)
        self.cleaner = lifecycle.Simulators(self.repo, self.host.run)

    def git(self, *args):
        return lifecycle.command(['git', '-C', str(self.repo), *args])

    def delete_worktree(self):
        self.git('worktree', 'remove', str(self.worktree))

    def test_association_is_idempotent_and_distinct_per_worktree(self):
        first = self.manager.ensure()
        self.assertEqual(self.manager.ensure(), first)
        second = self.cleaner.ensure()
        self.assertNotEqual(first, second)
        self.assertEqual(len(self.host.mutations), 2)
        self.assertEqual(self.cleaner.cleanup(True)['retained'], 2)

    def test_move_preserves_simulator_and_updates_registry(self):
        sid = self.manager.ensure()
        moved = self.root / 'moved'
        self.git('worktree', 'move', str(self.worktree), str(moved))
        report = self.cleaner.cleanup(True)
        self.assertEqual(report['retained'], 1)
        state = self.cleaner.load()
        self.assertEqual(next(iter(state['owners'].values()))['worktree'], str(moved))
        self.assertEqual(lifecycle.Simulators(moved, self.host.run).ensure(), sid)

    def test_dry_run_then_delete_only_registered_orphan(self):
        sid = self.manager.ensure()
        self.host.devices[sid]['state'] = 'Booted'
        unrelated = self.host.run(['xcrun', 'simctl', 'create', 'SB-legacy', MODEL, RUNTIME])
        self.delete_worktree()
        before = self.cleaner.registry.read_bytes()
        self.assertEqual(len(self.cleaner.cleanup()['orphans']), 1)
        self.assertEqual(self.cleaner.registry.read_bytes(), before)
        self.assertIn(sid, self.host.devices)
        self.assertEqual(self.cleaner.cleanup(True)['deleted'], [sid])
        self.assertIn(unrelated, self.host.devices)
        self.assertEqual(self.host.mutations[-2:], [['shutdown', sid], ['delete', sid]])
        self.assertEqual(self.cleaner.cleanup(True)['deleted'], [])

    def test_existing_directory_is_retained_after_git_metadata_pruned(self):
        sid = self.manager.ensure()
        admin = Path(next(iter(self.cleaner.load()['owners'].values()))['admin'])
        shutil.rmtree(admin)
        self.assertEqual(self.cleaner.cleanup(True)['retained'], 1)
        self.assertIn(sid, self.host.devices)

    def test_raw_directory_deletion_is_an_orphan_without_git_prune(self):
        sid = self.manager.ensure()
        shutil.rmtree(self.worktree)
        self.assertEqual(self.cleaner.cleanup(True)['deleted'], [sid])

    def test_absent_registry_never_adopts_legacy_names(self):
        sid = self.host.run(['xcrun', 'simctl', 'create', 'SB-legacy', MODEL, RUNTIME])
        self.assertEqual(self.cleaner.cleanup(True)['deleted'], [])
        self.assertIn(sid, self.host.devices)

    def test_reused_git_admin_directory_retires_only_old_owner(self):
        old_sid = self.manager.ensure()
        old_admin = next(iter(self.cleaner.load()['owners'].values()))['admin']
        self.delete_worktree()
        replacement = self.root / 'other' / self.worktree.name
        replacement.parent.mkdir()
        self.git('worktree', 'add', '--detach', str(replacement))
        new_manager = lifecycle.Simulators(replacement, self.host.run)
        new_sid = new_manager.ensure()
        self.assertEqual(new_manager.git('rev-parse', '--absolute-git-dir'), old_admin)
        report = self.cleaner.cleanup(True)
        self.assertEqual(report['deleted'], [old_sid])
        self.assertEqual(report['retained'], 1)
        self.assertIn(new_sid, self.host.devices)

    def test_replacement_at_same_path_gets_its_own_simulator(self):
        old_sid = self.manager.ensure()
        self.delete_worktree()
        self.git('worktree', 'add', '--detach', str(self.worktree))
        new_sid = self.manager.ensure()
        self.assertNotEqual(old_sid, new_sid)
        self.assertEqual(self.cleaner.cleanup(True)['deleted'], [old_sid])
        self.assertIn(new_sid, self.host.devices)

    def test_admin_reuse_preserves_original_directory_if_it_still_exists(self):
        old_sid = self.manager.ensure()
        admin = Path(next(iter(self.cleaner.load()['owners'].values()))['admin'])
        shutil.rmtree(admin)
        replacement = self.root / 'other' / self.worktree.name
        replacement.parent.mkdir()
        self.git('worktree', 'add', '--detach', str(replacement))
        new_sid = lifecycle.Simulators(replacement, self.host.run).ensure()
        report = self.cleaner.cleanup(True)
        self.assertEqual(report['retained'], 2)
        self.assertEqual(report['deleted'], [])
        self.assertEqual(set(self.host.devices), {old_sid, new_sid})

    def test_moving_replacement_before_cleanup_preserves_new_simulator(self):
        old_sid = self.manager.ensure()
        self.delete_worktree()
        self.git('worktree', 'add', '--detach', str(self.worktree))
        new_sid = self.manager.ensure()
        moved = self.root / 'moved'
        self.git('worktree', 'move', str(self.worktree), str(moved))
        report = self.cleaner.cleanup(True)
        self.assertEqual(report['deleted'], [old_sid])
        self.assertEqual(report['retained'], 1)
        self.assertIn(new_sid, self.host.devices)

    def test_crash_after_create_recovers_pending_uuid_without_duplicate(self):
        real_write = lifecycle.atomic_json
        calls = 0
        def write(path, state):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError('simulated interruption after simctl create')
            real_write(path, state)
        with patch.object(lifecycle, 'atomic_json', side_effect=write):
            with self.assertRaises(OSError):
                self.manager.ensure()
        self.assertIsNone(next(iter(self.cleaner.load()['owners'].values()))['udid'])
        self.assertEqual(self.manager.ensure(), next(iter(self.host.devices)))
        self.assertEqual(len(self.host.mutations), 1)

    def test_pending_creation_can_be_cleaned_after_worktree_deletion(self):
        sid = self.manager.ensure()
        state = self.cleaner.load()
        next(iter(state['owners'].values()))['udid'] = None
        lifecycle.atomic_json(self.cleaner.registry, state)
        self.delete_worktree()
        self.assertEqual(self.cleaner.cleanup(True)['deleted'], [sid])

    def test_missing_simulator_is_removed_from_registry(self):
        sid = self.manager.ensure()
        del self.host.devices[sid]
        self.delete_worktree()
        self.assertEqual(self.cleaner.cleanup(True)['missing'], [sid])
        self.assertEqual(self.cleaner.load()['owners'], {})

    def test_corrupt_registry_and_inventory_never_delete(self):
        sid = self.manager.ensure()
        self.delete_worktree()
        saved = self.cleaner.registry.read_text()
        for contents in ['{', '[]', '{"version": 2, "owners": {}}']:
            self.cleaner.registry.write_text(contents)
            with self.assertRaises((ValueError, lifecycle.LifecycleError)):
                self.cleaner.cleanup(True)
            self.assertIn(sid, self.host.devices)
        self.cleaner.registry.write_text(saved)
        for contents in ['{', '[]', '{"devices": {"runtime": [null]}}']:
            self.host.inventory = contents
            with self.assertRaises((ValueError, lifecycle.LifecycleError)):
                self.cleaner.cleanup(True)
            self.assertIn(sid, self.host.devices)

    def test_renamed_simulator_aborts_cleanup(self):
        sid = self.manager.ensure()
        self.delete_worktree()
        self.host.devices[sid]['name'] = 'someone-else'
        with self.assertRaises(lifecycle.LifecycleError):
            self.cleaner.cleanup(True)
        self.assertIn(sid, self.host.devices)

    def test_shutdown_or_delete_failure_preserves_registry_for_retry(self):
        sid = self.manager.ensure()
        self.delete_worktree()
        for failure in ['shutdown', 'delete']:
            self.host.devices[sid]['state'] = 'Booted'
            self.host.fail = failure
            with self.assertRaises(subprocess.CalledProcessError):
                self.cleaner.cleanup(True)
            self.assertIn(sid, self.host.devices)
            self.assertTrue(self.cleaner.load()['owners'])
        self.host.fail = None
        self.assertEqual(self.cleaner.cleanup(True)['deleted'], [sid])

    def test_owner_reappearing_during_shutdown_is_preserved(self):
        sid = self.manager.ensure()
        self.host.devices[sid]['state'] = 'Booted'
        self.delete_worktree()
        self.host.on_shutdown = self.worktree.mkdir
        with self.assertRaises(lifecycle.LifecycleError):
            self.cleaner.cleanup(True)
        self.assertIn(sid, self.host.devices)

    def test_unreadable_owner_metadata_aborts_before_deletion(self):
        sid = self.manager.ensure()
        entry = next(iter(self.cleaner.load()['owners'].values()))
        shutil.rmtree(self.worktree)
        (Path(entry['admin']) / 'super-simulator-owner').unlink()
        with self.assertRaises(OSError):
            self.cleaner.cleanup(True)
        self.assertIn(sid, self.host.devices)

    def test_stale_runtime_prevents_creation(self):
        self.host.build = '23E244'
        with self.assertRaises(lifecycle.LifecycleError):
            self.manager.ensure()
        self.assertEqual(self.host.mutations, [])

    def test_registry_lock_excludes_other_processes(self):
        code = '''import fcntl, sys
with open(sys.argv[1], 'a') as handle:
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit(7)
'''
        with self.manager.locked():
            result = subprocess.run([sys.executable, '-c', code, str(self.manager.directory / 'lock')])
        self.assertEqual(result.returncode, 7)
        self.assertEqual(subprocess.run([sys.executable, '-c', code, str(self.manager.directory / 'lock')]).returncode, 0)


if __name__ == '__main__':
    unittest.main()
