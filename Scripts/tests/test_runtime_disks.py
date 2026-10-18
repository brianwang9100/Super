import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from worktree_simulator import validate_runtime_disks


class RuntimeDiskTests(unittest.TestCase):
    def setUp(self):
        self.pin = {'ios_version': '27.0', 'ios_build': '24A434'}
        self.runtime = {'bundlePath': '/mount/active/iOS.simruntime'}
        self.active = {
            'runtimeIdentifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0',
            'build': '24A434', 'version': '27.0', 'path': '/asset/AssetData',
            'kind': 'Patchable Cryptex Disk Image', 'state': 'Ready',
            'runtimeBundlePath': self.runtime['bundlePath'],
        }
        self.old = dict(self.active, state='Unusable',
                        runtimeBundlePath='/mount/superseded/iOS.simruntime',
                        unusableSubstate='Cryptex Mount Preferred',
                        unusableErrorMessage='Cryptex Mount Preferred')

    def validate(self, old=None, runtime=None):
        validate_runtime_disks({'ready': self.active, 'old': old or self.old},
                               runtime or self.runtime, self.pin)

    def test_single_pinned_disk(self):
        validate_runtime_disks({'ready': self.active}, self.runtime, self.pin)

    def test_superseded_mount_of_same_asset(self):
        self.validate()

    def test_ambiguous_or_stale_records_are_rejected(self):
        for change in ({'build': '24A999'}, {'state': 'Ready'}, {'path': '/other/asset'},
                       {'unusableSubstate': 'Unknown'}, {'unusableErrorMessage': 'Unknown'},
                       {'kind': 'Disk Image'}, {'version': '27.1'}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.validate(old=dict(self.old, **change))

    def test_active_mount_must_match_available_runtime(self):
        with self.assertRaises(ValueError):
            self.validate(runtime={'bundlePath': self.old['runtimeBundlePath']})

    def test_missing_asset_identity_is_rejected(self):
        self.active['path'] = self.old['path'] = ''
        with self.assertRaises(ValueError):
            self.validate()

    def test_no_ready_disk_is_rejected(self):
        self.active['state'] = 'Unusable'
        with self.assertRaises(ValueError):
            self.validate()
