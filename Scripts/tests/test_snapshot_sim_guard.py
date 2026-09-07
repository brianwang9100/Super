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
    def decision(self, model, display_name='SuperWT-test-owner'):
        def run(args, **kwargs):
            if args == ['xcodebuild', '-version']:
                output = 'Xcode 26.4.1\nBuild version 17E202\n'
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
                patch('subprocess.run', side_effect=run), redirect_stdout(output):
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


if __name__ == '__main__':
    unittest.main()
