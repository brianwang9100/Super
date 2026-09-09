"""Exercise the complete capture driver without launching Xcode or a simulator."""
import json
import os
from pathlib import Path
import tempfile
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import run

PINS = run.read_pin(run.ROOT)


class CaptureDriverTests(unittest.TestCase):
    def test_explicit_existing_output_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'captures'
            output.mkdir()
            sentinel = output / 'keep.txt'
            sentinel.write_text('keep')
            with patch.object(run.sys, 'argv', ['run.py', '--argos', '--output', str(output)]):
                with self.assertRaisesRegex(SystemExit, 'already exists'):
                    run.main()
            self.assertEqual(sentinel.read_text(), 'keep')

    def capture(self, inspect=None, decoder_fails=False):
        runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'
        device = {'udid': 'owned', 'isAvailable': True,
                  'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'}
        outputs = ['Xcode 27.0\nBuild version 27A5252f', 'Version: 2.45.4',
                   json.dumps({'runtimes': [{'identifier': runtime, 'buildversion': '24A5423a', 'version': '27.0', 'isAvailable': True}]}),
                   json.dumps({'disk': {'runtimeIdentifier': runtime, 'build': '24A5423a'}}),
                   'owned', json.dumps({'devices': {runtime: [device]}})]
        captures = []
        def execute(command, **kwargs):
            if command[0] == 'swift' and decoder_fails:
                self.assertTrue(kwargs.get('check'), 'Decoder failure must stop staging')
                raise subprocess.CalledProcessError(1, command)
            if command[0] == 'xcodebuild':
                captures.append(command)
                if inspect:
                    inspect(command)
            return SimpleNamespace(returncode=0)
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(run, 'ROOT', Path(directory)), \
             patch.object(run, 'read_pin', return_value=PINS), \
             patch.object(run, 'output', side_effect=outputs), \
             patch.object(run, 'prepare', return_value=(Path(directory) / 'renderer', 'digest')), \
             patch.object(run.sys, 'argv', ['run.py']), \
             patch.dict(os.environ, {}, clear=True), \
             patch.object(run.subprocess, 'run', side_effect=execute):
            if decoder_fails:
                with patch.object(run.sys, 'argv', ['run.py', '--argos']):
                    with self.assertRaises(subprocess.CalledProcessError):
                        run.main()
                self.assertFalse((Path(directory) / 'screenshots').exists())
            else:
                run.main()
        return captures

    def test_failed_decoder_prevents_staging(self):
        self.capture(decoder_fails=True)

    def test_language_and_region_are_pinned_for_both_passes(self):
        captures = self.capture()
        self.assertEqual(len(captures), 2)
        for command in captures:
            self.assertIn('-testLanguage', command)
            self.assertEqual(command[command.index('-testLanguage') + 1], 'en')
            self.assertEqual(command[command.index('-testRegion') + 1], 'US')

    def test_both_passes_consume_committed_resolution(self):
        def inspect(command):
            project = Path(command[command.index('-project') + 1])
            lock = project / 'project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
            self.assertTrue(lock.is_file(), 'Capture must stage a reviewed dependency resolution')
            self.assertEqual(json.loads(lock.read_text())['pins'],
                             json.loads((run.HERE / 'Package.resolved').read_text())['pins'])
            self.assertIn('-onlyUsePackageVersionsFromResolvedFile', command)
        self.assertEqual(len(self.capture(inspect)), 2)

    def test_dependency_resolution_change_stops_capture(self):
        def mutate(command):
            project = Path(command[command.index('-project') + 1])
            lock = project / 'project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
            lock.parent.mkdir(parents=True, exist_ok=True)
            lock.write_text('{"pins": []}')
        with self.assertRaisesRegex(ValueError, 'resolution changed'):
            self.capture(mutate)
