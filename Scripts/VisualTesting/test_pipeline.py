"""Failure controls for complete, attributable visual uploads."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image

from pipeline import aggregate, inventories, validate_images, write_bundle, validate_rows
from capture import discover_suites, run_suites, verify_resolution


class PipelineTests(unittest.TestCase):
    def load_with_new_capture(self, row):
        read_text = Path.read_text
        def read_inventory(path, *args, **kwargs):
            contents = read_text(path, *args, **kwargs)
            if path.name == 'package-inventory.json':
                rows = json.loads(contents)
                contents = json.dumps([*rows, row])
            return contents
        with patch.object(Path, 'read_text', read_inventory):
            return inventories()

    def test_new_capture_has_explicit_identity_without_a_legacy_png(self):
        row = {'package': 'Todo', 'suite': 'TodoScreenSnapshotTests',
               'testName': 'populatedLight', 'captureName': 'populated_light',
               'image': 'Todo_TodoScreenSnapshotTests_populatedLight.populated_light.png',
               'pixels': [1206, 2622]}
        try:
            actual = self.load_with_new_capture(row)
        except KeyError as error:
            self.fail(f'New captures must not require historical PNG metadata: {error}')
        self.assertIn(row, actual['Todo'])
        self.assertEqual(sum(map(len, actual.values())), sum(map(len, inventories().values())) + 1)

    def test_new_capture_rejects_malformed_mismatched_and_ambiguous_identities(self):
        row = {'package': 'Todo', 'suite': 'TodoScreenSnapshotTests',
               'testName': 'populatedLight', 'captureName': 'populated_light',
               'image': 'Todo_TodoScreenSnapshotTests_populatedLight.populated_light.png',
               'pixels': [1206, 2622]}
        for change in ({'testName': ''}, {'testName': '../outside'}, {'captureName': None},
                       {'captureName': 'untrimmed-'}, {'suite': 'path/Other'},
                       {'image': 'Todo_Other_populatedLight.populated_light.png'},
                       {'legacy': 'populatedLight.populated_light.png'}, {'variant': 'dismissed'}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.load_with_new_capture({**row, **change})

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.identity = {'sha': 'abc', 'run_id': '42', 'run_attempt': '1'}
        self.expected = {'native': [{'image': 'native.png', 'pixels': [3, 2]}],
                         'Core': [{'image': 'Core.png', 'pixels': [3, 2]}]}

    def tearDown(self):
        self.temp.cleanup()

    def images(self, name):
        folder = self.root / name
        folder.mkdir()
        Image.new('RGBA', (3, 2), (4, 8, 12, 255)).save(folder / name)
        return folder

    def bundles(self):
        artifacts = self.root / 'artifacts'
        artifacts.mkdir()
        for shard, rows in self.expected.items():
            source = self.images(rows[0]['image'])
            write_bundle(source, artifacts / f'visual-{shard}', shard, rows, self.identity)
        return artifacts

    def test_complete_build_is_staged_only_after_all_shards_validate(self):
        artifacts = self.bundles()
        aggregate(artifacts, self.root / 'out', self.expected, self.identity)
        self.assertEqual(sorted(p.name for p in (self.root / 'out').iterdir()), ['Core.png', 'native.png'])

    def test_missing_shard_leaves_no_upload_directory(self):
        artifacts = self.bundles()
        (artifacts / 'visual-Core' / 'capture.json').unlink()
        with self.assertRaises(ValueError):
            aggregate(artifacts, self.root / 'out', self.expected, self.identity)
        self.assertFalse((self.root / 'out').exists())

    def test_wrong_revision_and_attempt_are_rejected(self):
        artifacts = self.bundles()
        for key in ('sha', 'run_id', 'run_attempt'):
            with self.subTest(key=key), self.assertRaises(ValueError):
                aggregate(artifacts, self.root / 'out', self.expected, {**self.identity, key: 'other'})

    def test_corrupt_png_payload_is_rejected(self):
        folder = self.images('test.png')
        path = folder / 'test.png'
        path.write_bytes(path.read_bytes()[:40])
        with self.assertRaises(ValueError):
            validate_images(folder, [{'image': 'test.png', 'pixels': [3, 2]}])

    def test_wrong_size_extra_file_and_missing_image_are_rejected(self):
        folder = self.images('test.png')
        with self.assertRaises(ValueError):
            validate_images(folder, [{'image': 'test.png', 'pixels': [2, 3]}])
        (folder / 'unexpected.json').write_text('{}')
        with self.assertRaises(ValueError):
            validate_images(folder, [{'image': 'test.png', 'pixels': [3, 2]}])
        (folder / 'unexpected.json').unlink()
        (folder / 'test.png').unlink()
        with self.assertRaises(ValueError):
            validate_images(folder, [{'image': 'test.png', 'pixels': [3, 2]}])

    def test_duplicate_cross_shard_names_are_rejected_before_flattening(self):
        artifacts = self.bundles()
        expected = {**self.expected, 'Core': self.expected['native']}
        with self.assertRaises(ValueError):
            aggregate(artifacts, self.root / 'out', expected, self.identity)

    def test_duplicate_and_traversing_inventory_names_are_rejected(self):
        for names in (['same.png', 'same.png'], ['../outside.png'], ['control\n.png']):
            with self.subTest(names=names), self.assertRaises(ValueError):
                validate_rows([{'image': name, 'pixels': [3, 2]} for name in names])

    def test_symlink_image_is_rejected(self):
        folder = self.root / 'images'
        folder.mkdir()
        target = self.root / 'external.png'
        Image.new('RGB', (3, 2)).save(target)
        (folder / 'test.png').symlink_to(target)
        with self.assertRaises(ValueError):
            validate_images(folder, [{'image': 'test.png', 'pixels': [3, 2]}])

    def test_changed_artifact_digest_is_rejected(self):
        artifacts = self.bundles()
        Image.new('RGBA', (3, 2), 'red').save(artifacts / 'visual-Core/images/Core.png')
        with self.assertRaises(ValueError):
            aggregate(artifacts, self.root / 'out', self.expected, self.identity)

    def test_extra_shard_and_wrong_manifest_owner_are_rejected(self):
        artifacts = self.bundles()
        extra = artifacts / 'visual-Old'
        extra.mkdir()
        with self.assertRaises(ValueError):
            aggregate(artifacts, self.root / 'out', self.expected, self.identity)
        extra.rmdir()
        path = artifacts / 'visual-Core/capture.json'
        manifest = json.loads(path.read_text())
        manifest['shard'] = 'native'
        path.write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            aggregate(artifacts, self.root / 'out', self.expected, self.identity)

    def test_invalid_input_cannot_publish_a_bundle(self):
        source = self.images('test.png')
        with self.assertRaises(ValueError):
            write_bundle(source, self.root / 'bundle', 'Core', self.expected['Core'], self.identity)
        self.assertFalse((self.root / 'bundle').exists())

    def test_existing_output_is_not_overwritten(self):
        artifacts = self.bundles()
        output = self.root / 'out'
        output.mkdir()
        (output / 'keep').write_text('keep')
        with self.assertRaises(ValueError):
            aggregate(artifacts, output, self.expected, self.identity)
        self.assertEqual((output / 'keep').read_text(), 'keep')


class DriverTests(unittest.TestCase):
    def test_dependency_resolution_change_is_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            resolved = Path(name) / 'Package.resolved'
            resolved.write_text(json.dumps({'pins': []}))
            with self.assertRaisesRegex(ValueError, 'resolution changed'):
                verify_resolution(resolved)

    def test_discovery_uses_suite_declaration_and_requires_serialization(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            folder = root / 'Packages/Todo/Tests/TodoTests/UI/Snapshots'
            folder.mkdir(parents=True)
            source = folder / 'ExampleSnapshotTests.swift'
            source.write_text('@Suite("Example", .serialized)\n@MainActor\nstruct DifferentSuiteName {}')
            self.assertEqual(discover_suites(root, 'Todo'), ['DifferentSuiteName'])
            source.write_text('@Suite("Example")\n@MainActor\nstruct DifferentSuiteName {}')
            with self.assertRaises(ValueError):
                discover_suites(root, 'Todo')

    def test_discovery_requires_uikit_behavior_suites(self):
        for package, suite in [('Chat', 'MessageListDeclarativeScrollTests'),
                               ('Bible', 'BiblePreviewPresentationObserverTests')]:
            with self.subTest(package=package), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                folder = root / f'Packages/{package}/Tests/{package}Tests/UI/Snapshots'
                folder.mkdir(parents=True)
                (folder / 'ExampleSnapshotTests.swift').write_text(
                    '@Suite("Visual", .serialized)\n@MainActor\nstruct ExampleSnapshotTests {}')
                behavior = folder.parent / f'{suite}.swift'
                with self.assertRaisesRegex(ValueError, 'Missing required capture suite'):
                    discover_suites(root, package)
                behavior.write_text(
                    '@Suite("Behavior", .serialized)\n@MainActor\n'
                    f'struct {suite} {{}}')
                self.assertEqual(discover_suites(root, package), ['ExampleSnapshotTests', suite])
                behavior.write_text(f'@Suite("Behavior")\n@MainActor\nstruct {suite} {{}}')
                with self.assertRaisesRegex(ValueError, 'must explicitly use .serialized'):
                    discover_suites(root, package)

    def test_failed_suite_stops_package_capture(self):
        calls = []
        def runner(command, **kwargs):
            calls.append(command)
            raise RuntimeError('capture failed')
        with tempfile.TemporaryDirectory() as name, self.assertRaises(RuntimeError):
            run_suites(['xcodebuild'], ['One', 'Two'], 'Core', Path(name), {}, runner=runner)
        self.assertEqual(len(calls), 1)

    def test_suites_execute_separately_and_zero_tests_fail(self):
        calls = []
        def runner(command, **kwargs):
            calls.append(command)
        with tempfile.TemporaryDirectory() as name, patch('capture.test_count', return_value=1):
            run_suites(['xcodebuild'], ['One', 'Two'], 'Core', Path(name), {}, runner=runner)
        self.assertEqual(len(calls), 2)
        self.assertIn('-only-testing:CoreTests/One', calls[0])
        self.assertNotIn('-only-testing:CoreTests/Two', calls[0])
        with tempfile.TemporaryDirectory() as name, patch('capture.test_count', return_value=0):
            with self.assertRaises(ValueError):
                run_suites(['xcodebuild'], ['One'], 'Core', Path(name), {}, runner=runner)


if __name__ == '__main__':
    unittest.main()
