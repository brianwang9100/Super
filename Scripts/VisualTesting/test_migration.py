"""Keep image baselines in Argos and test renderers out of app products."""
from pathlib import Path
import json
import re
import unittest

from pipeline import ROOT, PACKAGES, inventories


class MigrationPolicyTests(unittest.TestCase):
    def test_swift_64_transitive_issue_reporting_is_pinned_in_both_capture_locks(self):
        for owner in ('PreviewPilot', 'VisualTesting'):
            pins = json.loads((ROOT / f'Scripts/{owner}/Package.resolved').read_text())['pins']
            matches = [pin for pin in pins if pin['identity'] == 'swift-issue-reporting']
            self.assertEqual(len(matches), 1)
            self.assertEqual(matches[0]['state'], {
                'version': '2.1.0', 'revision': '71c7c9a761d1ca6ed4ccb6ced040fe1c1a39e8e7'})

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
