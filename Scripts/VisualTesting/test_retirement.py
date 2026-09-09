"""Ensure retired capture coverage still has registered visual and behavioral owners."""
import json
from pathlib import Path
import re
import unittest

from pipeline import ROOT, inventories


class RetirementCoverageTests(unittest.TestCase):
    def test_retirements_keep_live_visual_and_behavioral_evidence(self):
        registered = set()
        for package, rows in inventories().items():
            for row in rows:
                if package == 'native':
                    path = Path('Scripts/PreviewPilot/__Snapshots__') / row['image']
                else:
                    prefix = f'{package}_{row["suite"]}_'
                    path = (Path(f'Packages/{package}/Tests/{package}Tests/UI/Snapshots/__Snapshots__')
                            / row['suite'] / row['image'].removeprefix(prefix))
                registered.add(path.as_posix())
        rows = json.loads((ROOT / 'Scripts/VisualTesting/retired-coverage.json').read_text())
        retired = [row['retiredPNG'] for row in rows]
        self.assertEqual(len(retired), len(set(retired)), 'Duplicate retirement records')
        for row in rows:
            with self.subTest(retired=row['retiredPNG']):
                self.assertNotIn(row['retiredPNG'], registered)
                self.assertFalse((ROOT / row['retiredPNG']).exists())
                self.assertTrue(row['rationale'].strip())
                for retained in [row['retainedPNG'], *row.get('retainedPNGs', [])]:
                    self.assertIn(retained, registered, 'Replacement must remain in compared inventory')
                    self.assertTrue((ROOT / retained).is_file(), retained)
                evidence = [{'file': row['behavioralFile'], 'tests': row['behavioralTests']},
                            *row.get('behavioralEvidence', [])]
                for owner in evidence:
                    source = (ROOT / owner['file']).read_text()
                    self.assertTrue(owner['tests'], 'Name concrete behavioral test declarations')
                    for name in owner['tests']:
                        self.assertRegex(source, rf'\bfunc\s+{re.escape(name)}\s*\(',
                                         f'Missing behavioral owner: {owner["file"]}:{name}')
