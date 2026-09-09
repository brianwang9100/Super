"""The shell hook must deny concrete simulator commands if Python cannot run."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

WRAPPER = Path(__file__).resolve().parents[2] / '.codex/hooks/enforce-snapshot-sim.sh'


class WrapperTests(unittest.TestCase):
    def invoke(self, python):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for name in ('cat', 'dirname'):
                (folder / name).symlink_to('/bin/' + name if name == 'cat' else '/usr/bin/' + name)
            if python:
                stub = folder / 'python3'
                stub.write_text('#!/bin/bash\nexit 7\n')
                stub.chmod(0o755)
            payload = json.dumps({'tool_input': {'cmd': 'xcodebuild test -destination "platform=iOS Simulator,id=fixture"'}})
            return subprocess.run(['/bin/bash', str(WRAPPER)], input=payload, text=True,
                                  capture_output=True, env={**os.environ, 'PATH': directory})

    def test_missing_python_denies(self):
        result = self.invoke(False)
        self.assertEqual(json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'], 'deny')

    def test_crashed_python_denies(self):
        result = self.invoke(True)
        self.assertEqual(json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'], 'deny')
