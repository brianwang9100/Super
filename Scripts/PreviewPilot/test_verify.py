"""Regression checks for false-green discovery/export results."""
import tempfile
import unittest
from pathlib import Path
from verify import expected_names, verify_names, verify_exports, verify_sources, verify_dimensions, UIKIT
from run import validate_migration_report


class InventoryTests(unittest.TestCase):
    def test_migration_allows_pixels_but_rejects_incomplete_or_invalid_comparisons(self):
        rows = [{'image': name, 'status': 'pixel-mismatch'} for name in expected_names()
                if name.startswith('Chat_')]
        validate_migration_report(rows)
        for invalid in ([], rows[:-1], rows + [rows[0]],
                        [dict(rows[0], status='dimension-mismatch')] + rows[1:],
                        [dict(rows[0], status='missing-or-invalid-image')] + rows[1:]):
            with self.assertRaises(ValueError):
                validate_migration_report(invalid)

    def test_source_identity_and_unchanged_baselines(self):
        verify_sources()

    def test_complete_discovery(self):
        verify_names(list(reversed(expected_names())))

    def test_empty_missing_extra_duplicate_and_renamed_discovery(self):
        valid = expected_names()
        for invalid in [[], valid[:-1], valid + ['extra.png'], valid + [valid[0]],
                        ['renamed.png'] + valid[1:]]:
            with self.subTest(names=invalid), self.assertRaises(ValueError):
                verify_names(invalid)

    def test_empty_exports_fail(self):
        with tempfile.TemporaryDirectory() as folder, self.assertRaises(ValueError):
            verify_exports(Path(folder))

    def test_missing_sidecars_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            for name in expected_names():
                (Path(folder) / name).touch()
            with self.assertRaises(ValueError):
                verify_exports(Path(folder))

    def test_fractional_intrinsic_height_contract(self):
        name = 'Chat_ChatComposerPreviews.swift_composer_font_scale_max_light_xxl.png'
        verify_dimensions(name, 1206, 352)
        with self.assertRaises(ValueError):
            verify_dimensions(name, 1206, 354)

    def test_fixed_viewport_dimension_contract(self):
        verify_dimensions(UIKIT, 1206, 540)
        with self.assertRaises(ValueError):
            verify_dimensions(UIKIT, 1206, 2016)


if __name__ == '__main__':
    unittest.main()
