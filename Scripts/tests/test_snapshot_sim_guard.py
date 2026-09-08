"""Regression coverage for custom-named, worktree-owned simulator destinations."""

from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import runpy
import subprocess
import unittest
from unittest.mock import patch

HOOK = Path(__file__).resolve().parents[2] / '.codex/hooks/enforce-snapshot-sim.py'
UDID = 'B87FDEDA-EEB0-4CFA-9DDE-8781E8982455'


class SnapshotSimulatorGuardTests(unittest.TestCase):
    def decision(self, model, display_name='SuperWT-test-owner', pin_override=None, xcode_build='17E202'):
        original_read = Path.read_text
        def read_text(path, *args, **kwargs):
            if path.name == 'simulator-pins.json' and pin_override is not None:
                return json.dumps(pin_override)
            return original_read(path, *args, **kwargs)
        def run(args, **kwargs):
            if args == ['xcodebuild', '-version']:
                output = f'Xcode 26.4.1\nBuild version {xcode_build}\n'
            elif args[3] == 'runtimes':
                output = json.dumps({'runtimes': [{'isAvailable': True,
                    'version': '26.4.1', 'buildversion': '23E254a'}]})
            elif args[3] == 'devices':
                output = json.dumps({'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-4': [
                    {'udid': UDID, 'name': display_name,
                     'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.' + model.replace(' ', '-')}]}})
            elif args[3] == 'devicetypes':
                output = json.dumps({'devicetypes': [{'name': name,
                    'identifier': 'com.apple.CoreSimulator.SimDeviceType.' + name.replace(' ', '-')}
                    for name in ['iPhone 16', 'iPhone 17']]})
            else:
                raise AssertionError(args)
            return subprocess.CompletedProcess(args, 0, stdout=output)
        payload = {'tool_input': {'cmd': f'xcodebuild test -destination "platform=iOS Simulator,id={UDID}"'}}
        output = io.StringIO()
        with patch('sys.stdin', io.StringIO(json.dumps(payload))), \
                patch('subprocess.run', side_effect=run), \
                patch.object(Path, 'read_text', read_text), redirect_stdout(output):
            with self.assertRaises(SystemExit) as exited:
                runpy.run_path(str(HOOK), run_name='__main__')
        self.assertEqual(exited.exception.code, 0)
        return output.getvalue()

    def test_custom_name_on_pinned_model_is_allowed(self):
        self.assertEqual(self.decision('iPhone 17'), '')

    def test_custom_name_on_wrong_model_is_denied(self):
        self.assertIn('deny', self.decision('iPhone 16'))

    def test_display_name_cannot_disguise_wrong_model(self):
        self.assertIn('deny', self.decision('iPhone 16', display_name='iPhone 17'))

    def test_same_xcode_version_with_wrong_build_is_denied(self):
        self.assertIn('deny', self.decision('iPhone 17', xcode_build='17E999'))

    def test_guard_uses_canonical_pin_instead_of_removed_workflow_job(self):
        pin = json.loads((HOOK.parents[2] / 'Scripts/VisualTesting/simulator-pins.json').read_text())
        pin['device'] = 'iPhone 16'
        self.assertEqual(self.decision('iPhone 16', pin_override=pin), '')
        self.assertIn('deny', self.decision('iPhone 17', pin_override=pin))

    def test_invalid_canonical_pin_does_not_fall_back_to_stale_constants(self):
        self.assertIn('Cannot read canonical simulator pins',
                      self.decision('iPhone 17', pin_override={}))


if __name__ == '__main__':
    unittest.main()
