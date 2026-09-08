"""A failed local capture must leave no stale or partial upload folder."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import run


class LocalCaptureTests(unittest.TestCase):
    def test_failed_guard_native_or_package_capture_removes_previous_upload(self):
        for failure_at in (1, 2, 3):
            with self.subTest(failure_at=failure_at), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                output = root / 'screenshots'
                output.mkdir()
                (output / 'stale.png').write_bytes(b'stale')
                calls = []

                def capture(command, **kwargs):
                    calls.append(command)
                    if len(calls) == failure_at:
                        raise subprocess.CalledProcessError(1, command)

                with patch.object(run, 'ROOT', root), patch.object(run, 'PACKAGES', ('Core',)), \
                        patch.object(run, 'inventories', return_value={'native': [], 'Core': []}), \
                        patch.object(run, 'identity', return_value={'sha': 'one'}), \
                        patch.object(run, 'write_bundle'), patch.object(run.subprocess, 'run', side_effect=capture), \
                        patch.object(run, 'aggregate') as publish:
                    with self.assertRaises(subprocess.CalledProcessError):
                        run.main()
                    publish.assert_not_called()
                self.assertFalse(output.exists())

    def test_changed_revision_cannot_publish_captures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(run, 'ROOT', root), patch.object(run, 'PACKAGES', ()), \
                    patch.object(run, 'inventories', return_value={'native': []}), \
                    patch.object(run, 'identity', side_effect=[{'sha': 'one'}, {'sha': 'two'}]), \
                    patch.object(run, 'write_bundle'), patch.object(run.subprocess, 'run'), \
                    patch.object(run, 'aggregate') as publish:
                with self.assertRaisesRegex(ValueError, 'Checkout changed'):
                    run.main()
                publish.assert_not_called()
            self.assertFalse((root / 'screenshots').exists())
