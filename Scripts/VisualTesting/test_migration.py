"""Keep repository image baselines complete and production fixtures comparing."""
from pathlib import Path
import unittest

from pipeline import ROOT, PACKAGES, inventories, validate_images


class MigrationPolicyTests(unittest.TestCase):
    def test_each_inventory_owner_has_a_comparing_fixture(self):
        for package, rows in inventories().items():
            if package == 'native':
                continue
            for suite in {row['suite'] for row in rows}:
                path = ROOT / f'Packages/{package}/Tests/{package}Tests/UI/Snapshots/{suite}.swift'
                self.assertTrue(path.is_file(), str(path))
                source = path.read_text()
                self.assertIn('verifyVisualSnapshot(', source, str(path))
                self.assertNotIn('directory:', source, 'Production fixtures must not override baseline storage')

    def test_repository_baselines_match_complete_inventory(self):
        for package, rows in inventories().items():
            if package == 'native':
                validate_images(ROOT / 'Scripts/PreviewPilot/__Snapshots__', rows)
                continue
            base = ROOT / f'Packages/{package}/Tests/{package}Tests/UI/Snapshots/__Snapshots__'
            suites = {row['suite'] for row in rows}
            self.assertEqual({p.name for p in base.iterdir() if not p.is_dir() or any(p.iterdir())}, suites)
            for suite in suites:
                prefix = f'{package}_{suite}_'
                expected = [{**row, 'image': row['image'].removeprefix(prefix)}
                            for row in rows if row['suite'] == suite]
                validate_images(base / suite, expected)
