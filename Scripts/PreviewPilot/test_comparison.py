"""Regression checks for fail-closed repository comparison and local recording."""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image
import comparison
import verify


class RepositoryComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.exports, self.baselines = self.root / 'exports', self.root / 'baselines'
        self.exports.mkdir()
        self.baselines.mkdir()
        self.name = 'Chat_Test.swift_probe.png'
        inventory = patch.object(verify, 'inventory_rows', return_value=[
            {'image': self.name, 'pixels': [2, 1]}])
        inventory.start()
        self.addCleanup(inventory.stop)
        for name, dimensions in ((self.name, (2, 1)), (verify.UIKIT, (1206, 540)), (verify.FONTS, (1206, 540))):
            image = Image.new('RGBA', dimensions, (100, 50, 20, 255))
            for folder in (self.exports, self.baselines):
                image.save(folder / name)
            display = name.split('.swift_', 1)[1].removesuffix('.png')
            (self.exports / name).with_suffix('.json').write_text(json.dumps({
                'display_name': display, 'context': {'preview': {'display_name': display}}}))

    def compare(self):
        return comparison.compare(self.exports, self.root / 'evidence', baselines=self.baselines)

    def snapshot(self):
        return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in self.baselines.iterdir()}

    def test_default_comparison_passes_without_rewriting_baselines(self):
        before = self.snapshot()
        self.assertTrue(self.compare()['passed'])
        self.assertEqual(before, self.snapshot())

    def test_png_encoding_differences_do_not_fail_equal_pixels(self):
        with Image.open(self.exports / self.name) as image:
            image.save(self.exports / self.name, compress_level=0)
        self.assertNotEqual((self.exports / self.name).read_bytes(), (self.baselines / self.name).read_bytes())
        self.assertTrue(self.compare()['passed'])

    def test_changed_single_channel_pixel_fails_and_preserves_evidence(self):
        before = self.snapshot()
        with Image.open(self.exports / self.name) as image:
            image.putpixel((0, 0), (101, 50, 20, 255))
            image.save(self.exports / self.name)
        with self.assertRaisesRegex(ValueError, 'comparison failed'):
            self.compare()
        self.assertEqual(before, self.snapshot())
        for kind in ('expected', 'actual', 'diff'):
            self.assertTrue((self.root / 'evidence' / kind / self.name).is_file())
        summary = json.loads((self.root / 'evidence/summary.json').read_text())
        row = next(row for row in summary['images'] if row['image'] == self.name)
        self.assertEqual(row['changedPixels'], 1)
        self.assertEqual(row['maxChannelDelta'], 1)

    def test_alpha_only_change_fails(self):
        with Image.open(self.exports / self.name) as image:
            image.putpixel((0, 0), (100, 50, 20, 254))
            image.save(self.exports / self.name)
        with self.assertRaisesRegex(ValueError, 'comparison failed'):
            self.compare()
        self.assertTrue((self.root / 'evidence/diff' / self.name).is_file())

    def test_bounded_rounding_accepts_only_rgb_delta_one_within_pixel_limit(self):
        # 100x100 makes exactly one changed pixel the inclusive 0.01% boundary.
        cases = [('accepted', [(101, 50, 20, 255)], True),
                 ('rgb-too-large', [(102, 50, 20, 255)], False),
                 ('alpha-changed', [(100, 50, 20, 254)], False),
                 ('too-many-pixels', [(101, 50, 20, 255), (100, 51, 20, 255)], False)]
        with patch.object(verify, 'inventory_rows', return_value=[
                {'image': self.name, 'pixels': [100, 100]}]):
            Image.new('RGBA', (100, 100), (100, 50, 20, 255)).save(self.baselines / self.name)
            before = self.snapshot()
            for label, pixels, passes in cases:
                with self.subTest(case=label):
                    actual = Image.new('RGBA', (100, 100), (100, 50, 20, 255))
                    for index, pixel in enumerate(pixels):
                        actual.putpixel((index, 0), pixel)
                    actual.save(self.exports / self.name)
                    artifacts = self.root / label
                    if passes:
                        summary = comparison.compare(self.exports, artifacts, baselines=self.baselines)
                        self.assertTrue(summary['passed'])
                        self.assertEqual(summary['acceptedRoundingImages'], 1)
                        self.assertEqual(summary['acceptedRoundingPixels'], 1)
                        row = next(row for row in summary['images'] if row['image'] == self.name)
                        self.assertEqual(row['status'], 'accepted-rounding')
                        self.assertEqual(row['maxAlphaChannelDelta'], 0)
                        self.assertEqual(row['changedPixelFraction'], 0.0001)
                        for kind in ('expected', 'actual', 'diff'):
                            self.assertTrue((artifacts / kind / self.name).is_file())
                    else:
                        with self.assertRaisesRegex(ValueError, 'comparison failed'):
                            comparison.compare(self.exports, artifacts, baselines=self.baselines)
                    self.assertEqual(before, self.snapshot())

    def test_missing_baseline_fails_without_recording(self):
        (self.baselines / self.name).unlink()
        with self.assertRaisesRegex(ValueError, 'comparison failed'):
            self.compare()
        self.assertFalse((self.baselines / self.name).exists())

    def test_missing_capture_fails(self):
        (self.exports / self.name).unlink()
        with self.assertRaisesRegex(ValueError, 'comparison failed'):
            self.compare()

    def test_extra_baseline_and_capture_fail(self):
        for folder in (self.baselines, self.exports):
            with self.subTest(folder=folder):
                extra = folder / 'unexpected.png'
                extra.write_bytes((folder / self.name).read_bytes())
                with self.assertRaisesRegex(ValueError, 'comparison failed'):
                    comparison.compare(self.exports, self.root / ('extra-' + folder.name), baselines=self.baselines)
                extra.unlink()

    def test_corrupt_payloads_fail_on_both_sides(self):
        for index, folder in enumerate((self.baselines, self.exports)):
            with self.subTest(folder=folder):
                path = folder / self.name
                original = path.read_bytes()
                path.write_bytes(original[:33] + comparison.PNG_END)
                with self.assertRaisesRegex(ValueError, 'comparison failed'):
                    comparison.compare(self.exports, self.root / f'corrupt-{index}', baselines=self.baselines)
                path.write_bytes(original)

    def test_wrong_dimensions_fail_on_both_sides(self):
        for index, folder in enumerate((self.baselines, self.exports)):
            with self.subTest(folder=folder):
                path = folder / self.name
                original = path.read_bytes()
                Image.new('RGBA', (3, 1)).save(path)
                with self.assertRaisesRegex(ValueError, 'comparison failed'):
                    comparison.compare(self.exports, self.root / f'dimensions-{index}', baselines=self.baselines)
                path.write_bytes(original)

    def test_record_requires_complete_validated_inventory(self):
        before = self.snapshot()
        (self.exports / verify.FONTS).write_bytes(b'corrupt')
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(ValueError):
            comparison.record(self.exports, self.root / 'record', baselines=self.baselines)
        self.assertEqual(before, self.snapshot())

    def test_recording_rejected_in_ci_before_any_mutation(self):
        for key in ('CI', 'GITHUB_ACTIONS'):
            with self.subTest(key=key), patch.dict(os.environ, {key: 'true'}, clear=True):
                before = self.snapshot()
                with self.assertRaisesRegex(ValueError, 'forbidden'):
                    comparison.record(self.exports, self.root / 'record', baselines=self.baselines)
                self.assertEqual(before, self.snapshot())
                self.assertFalse((self.root / 'record').exists())

    def test_explicit_local_recording_replaces_full_inventory(self):
        (self.baselines / self.name).unlink()
        with patch.dict(os.environ, {}, clear=True):
            self.assertTrue(comparison.record(self.exports, self.root / 'record', baselines=self.baselines)['passed'])
        self.assertEqual((self.exports / self.name).read_bytes(), (self.baselines / self.name).read_bytes())

    def test_recording_does_not_silently_prune_unexpected_baselines(self):
        (self.baselines / 'unexpected.png').write_bytes(b'keep')
        before = self.snapshot()
        with patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(ValueError, 'silently delete'):
            comparison.record(self.exports, self.root / 'record', baselines=self.baselines)
        self.assertEqual(before, self.snapshot())
