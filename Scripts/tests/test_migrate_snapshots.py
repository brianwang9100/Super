"""Fail-closed coverage for the hosted screenshot migration's safety checks."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("migrate_snapshots", Path(__file__).parents[1] / "migrate_snapshots.py")
migration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(migration)


class MigrationValidationTests(unittest.TestCase):
    def fixture(self, failed=0, message=None):
        summary = {
            "totalTestCount": 1, "passedTests": 1 - failed, "failedTests": failed,
            "skippedTests": 0, "expectedFailures": 0,
            "result": "Failed" if failed else "Passed", "testFailures": [],
        }
        tree = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": "ExampleSnapshotTests/screen()",
                               "result": "Failed" if failed else "Passed"}]}
        legacy = {"issues": {"testFailureSummaries": {"_values": []}}}
        if message is not None:
            legacy["issues"]["testFailureSummaries"]["_values"].append({"message": {"_value": message}})
        return summary, tree, legacy

    def validate(self, reports, phase="original", status=0, suites=None):
        return migration.validate_report(*reports, status, phase, suites or ["ExampleSnapshotTests"])

    def test_original_comparison_failures_are_allowed(self):
        report = self.validate(self.fixture(1, 'Snapshot "light" does not match reference.'), status=65)
        self.assertEqual(report["total"], 1)

    def test_recording_assertions_are_allowed(self):
        self.validate(self.fixture(1, "Record mode is on. Automatically recorded snapshot: …"), "record", 65)

    def test_verification_requires_success(self):
        self.validate(self.fixture(), "verify")
        with self.assertRaises(migration.MigrationError):
            self.validate(self.fixture(1, "Snapshot does not match reference."), "verify", 65)

    def test_zero_tests_fail(self):
        reports = self.fixture()
        reports[0].update(totalTestCount=0, passedTests=0)
        with self.assertRaises(migration.MigrationError):
            self.validate(reports)

    def test_skipped_tests_fail(self):
        reports = self.fixture()
        reports[0]["skippedTests"] = 1
        with self.assertRaises(migration.MigrationError):
            self.validate(reports)

    def test_suite_matching_no_tests_fails(self):
        with self.assertRaises(migration.MigrationError):
            self.validate(self.fixture(), suites=["MissingSnapshotTests"])

    def test_unexpected_xcodebuild_exit_fails(self):
        with self.assertRaises(migration.MigrationError):
            self.validate(self.fixture(), status=70)

    def test_missing_failure_details_fail(self):
        with self.assertRaises(migration.MigrationError):
            self.validate(self.fixture(1), status=65)

    def test_compile_error_is_not_hidden_by_snapshot_failure(self):
        reports = self.fixture(1, "Snapshot does not match reference.")
        reports[2]["actions"] = [{"buildResult": {"issues": {
            "errorSummaries": {"_values": [{"message": {"_value": "Cannot find type"}}]}
        }}}]
        with self.assertRaises(migration.MigrationError):
            self.validate(reports, status=65)

    def test_non_snapshot_test_failure_fails(self):
        with self.assertRaises(migration.MigrationError):
            self.validate(self.fixture(1, "Expectation failed: value == 3"), status=65)

    def test_timeout_failure_fails(self):
        with self.assertRaises(migration.MigrationError):
            self.validate(self.fixture(1, "Exceeded timeout of 5.0 seconds waiting for snapshot."), status=65)

    def test_recording_cannot_pass_without_using_recording_seam(self):
        with self.assertRaises(migration.MigrationError):
            self.validate(self.fixture(), "record")
        with self.assertRaises(migration.MigrationError):
            self.validate(self.fixture(1, "No reference was found on disk. Automatically recorded snapshot: …"),
                          "record", 65)

    def test_original_pass_rejects_missing_reference(self):
        with self.assertRaises(migration.MigrationError):
            self.validate(self.fixture(1, "No reference was found on disk. New snapshot was not recorded"), status=65)

    def test_modern_summary_failure_is_also_validated(self):
        reports = self.fixture(1, "Snapshot does not match reference.")
        reports[0]["testFailures"] = [{"failureText": "Unexpected process termination"}]
        with self.assertRaises(migration.MigrationError):
            self.validate(reports, status=65)

    def test_discovery_uses_suite_name_and_requires_every_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source = directory / "DifferentFilenameSnapshotTests.swift"
            source.write_text('@Suite("Display name")\n@MainActor\nstruct ActualSnapshotTests {}\n')
            self.assertEqual(migration.discover_suites(directory), ["ActualSnapshotTests"])
            (directory / "BrokenSnapshotTests.swift").write_text("// Missing suite\n")
            with self.assertRaises(migration.MigrationError):
                migration.discover_suites(directory)

    def test_missing_or_unexpected_png_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "Snapshots"
            directory.mkdir()
            with self.assertRaises(migration.MigrationError):
                migration.assert_png_inventory(root, directory, ["Snapshots/reference.png"])
            (directory / "unexpected.png").write_bytes(b"test")
            with self.assertRaises(migration.MigrationError):
                migration.assert_png_inventory(root, directory, [])

    def test_fingerprints_reject_invalid_png(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "reference.png").write_bytes(b"not a PNG")
            with self.assertRaises(migration.MigrationError):
                migration.fingerprints(root, ["reference.png"])


if __name__ == "__main__":
    unittest.main()
