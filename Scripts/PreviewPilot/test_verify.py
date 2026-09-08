"""Regression checks for false-green discovery/export results."""
import tempfile
import unittest
from pathlib import Path
from verify import expected_names, verify_names, verify_exports, verify_sources, verify_dimensions, UIKIT


class InventoryTests(unittest.TestCase):
    def test_settings_group_is_required_and_dimensions_are_fixed(self):
        names = expected_names()
        settings = [name for name in names if '_SettingsPanePreviews.swift_' in name]
        self.assertEqual(len(settings), 18)
        with self.assertRaises(ValueError):
            verify_names([name for name in names if name not in settings])
        pane = 'Chat_SettingsPanePreviews.swift_settings_root_light.png'
        verify_dimensions(pane, 1206, 2622)
        with self.assertRaises(ValueError):
            verify_dimensions(pane, 1206, 4020)

    def test_full_appearance_gallery_keeps_all_theme_rows(self):
        name = 'Chat_SettingsPanePreviews.swift_settings_appearance_haptics_light.png'
        verify_dimensions(name, 1206, 4020)
        with self.assertRaises(ValueError):
            verify_dimensions(name, 1206, 2622)

    def test_source_identity(self):
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
        verify_dimensions(name, 1206, 376)
        with self.assertRaises(ValueError):
            verify_dimensions(name, 1206, 378)

    def test_fixed_viewport_dimension_contract(self):
        verify_dimensions(UIKIT, 1206, 540)
        with self.assertRaises(ValueError):
            verify_dimensions(UIKIT, 1206, 2016)


if __name__ == '__main__':
    unittest.main()
