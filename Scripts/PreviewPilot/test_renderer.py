"""Regression checks for cached renderer integrity and worktree simulator isolation."""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from prepare_renderer import validate_checkout
import run


class RendererIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git('init', '-q')
        (self.root / 'Sources').mkdir()
        (self.root / 'Sources/Renderer.swift').write_text('let value = 1\n')
        (self.root / '.gitignore').write_text('*.extra.swift\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null',
                 'commit', '-qm', 'Fixture')
        self.revision = self.git('rev-parse', 'HEAD').decode().strip()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args])

    def test_clean_checkout_passes(self):
        validate_checkout(self.root, self.revision, b'')

    def test_untracked_source_is_rejected(self):
        (self.root / 'Sources/Extra.swift').write_text('let extra = 2\n')
        with self.assertRaises(ValueError):
            validate_checkout(self.root, self.revision, b'')

    def test_ignored_source_is_also_rejected(self):
        (self.root / 'Sources/ignored.extra.swift').write_text('let extra = 2\n')
        with self.assertRaises(ValueError):
            validate_checkout(self.root, self.revision, b'')

    def test_tracked_edit_requires_exact_patch(self):
        (self.root / 'Sources/Renderer.swift').write_text('let value = 3\n')
        with self.assertRaises(ValueError):
            validate_checkout(self.root, self.revision, b'')
        validate_checkout(self.root, self.revision, self.git('diff', '--binary', 'HEAD'))


class RegisteredSimulatorTests(unittest.TestCase):
    def capture(self, supplied=None):
        runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-26-4'
        device = {'udid': 'owned-uuid', 'name': 'SuperWT-registered', 'isAvailable': True,
                  'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'}
        def output(*command):
            if command == ('xcodebuild', '-version'):
                return 'Xcode 26.4.1\nBuild version 17E202'
            if command == ('xcodegen', '--version'):
                return 'Version: 2.45.4'
            if command == ('xcrun', 'simctl', 'list', 'runtimes', '-j'):
                return json.dumps({'runtimes': [{'identifier': runtime, 'buildversion': '23E254a', 'version': '26.4.1', 'isAvailable': True}]})
            if command == ('xcrun', 'simctl', 'runtime', 'list', '-j'):
                return json.dumps({'disk': {'runtimeIdentifier': runtime, 'build': '23E254a'}})
            if command == ('xcrun', 'simctl', 'list', 'devices', '-j'):
                return json.dumps({'devices': {runtime: [device]}})
            if command == (run.sys.executable, str(run.ROOT / 'Scripts/worktree_simulator.py'), 'ensure', '--repo', str(run.ROOT)):
                return device['udid']
            self.fail(f'Unexpected command (must not create a second simulator): {command}')
        with patch.object(run, 'output', side_effect=output), \
             patch.object(run.sys, 'argv', ['run.py'] + ([supplied] if supplied else [])), \
             patch.dict(os.environ, {}, clear=True), \
             patch.object(run, 'prepare', side_effect=CaptureReady):
            run.main()

    def test_default_capture_reuses_registered_device(self):
        with self.assertRaises(CaptureReady):
            self.capture()

    def test_explicit_registered_device_is_accepted(self):
        with self.assertRaises(CaptureReady):
            self.capture('owned-uuid')

    def test_other_worktree_device_is_rejected(self):
        with self.assertRaisesRegex(SystemExit, 'registered worktree simulator'):
            self.capture('another-worktree-uuid')


class CaptureReady(Exception):
    """Stop before renderer preparation once simulator selection has succeeded."""
