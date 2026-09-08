"""Keep image baselines in Argos and test renderers out of app products."""
from pathlib import Path
import re
import unittest

from pipeline import ROOT, PACKAGES, inventories


class MigrationPolicyTests(unittest.TestCase):
    def test_no_repository_ui_image_baselines_or_comparison_calls(self):
        violations = []
        for package in PACKAGES:
            folder = ROOT / f'Packages/{package}/Tests/{package}Tests/UI'
            violations.extend(str(path.relative_to(ROOT)) for path in folder.rglob('*.png'))
            for path in folder.rglob('*.swift'):
                if re.search(r'\b(?:verifySnapshot|assertSnapshot|assertSnapshots)\s*\(', path.read_text()):
                    violations.append(str(path.relative_to(ROOT)))
        self.assertEqual(violations, [], 'Use capture-only exports and reviewed Argos baselines')

    def test_each_capture_inventory_owner_has_a_migrated_fixture(self):
        for package, rows in inventories().items():
            if package == 'native':
                continue
            for suite in {row['suite'] for row in rows}:
                path = ROOT / f'Packages/{package}/Tests/{package}Tests/UI/Snapshots/{suite}.swift'
                self.assertTrue(path.is_file(), str(path))
                self.assertIn('verifyVisualSnapshot(', path.read_text(), str(path))
