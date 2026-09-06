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

    def test_toolchain_mode_never_allows_additions(self):
        self.assertEqual(migration.approved_additions("Chat", "toolchain"), {})

    def test_toolchain_matrix_supports_each_scheme_or_all(self):
        for scheme in ("Core", "Chat", "Bible", "Todo"):
            self.assertEqual(migration.requested_schemes(scheme, "toolchain"), [scheme])
        self.assertEqual(migration.requested_schemes("all", "toolchain"), ["Core", "Chat", "Bible", "Todo"])

    def test_pcc_matrix_cannot_select_all_or_another_package(self):
        self.assertEqual(migration.requested_schemes("Chat", "pcc-registration"), ["Chat"])
        for selection in ("all", "Core", "Bible", "Todo"):
            with self.assertRaises(migration.MigrationError):
                migration.requested_schemes(selection, "pcc-registration")

    def test_matrix_rejects_unrecognized_mode_and_selection(self):
        with self.assertRaises(migration.MigrationError):
            migration.requested_schemes("Unknown", "toolchain")
        with self.assertRaises(migration.MigrationError):
            migration.requested_schemes("Chat", "unknown-mode")

    def test_pcc_mode_is_chat_only(self):
        with self.assertRaises(migration.MigrationError):
            migration.approved_additions("Core", "pcc-registration")

    def test_pcc_mode_approves_exact_26_paths(self):
        additions = migration.approved_additions("Chat", "pcc-registration")
        self.assertEqual(len(additions), 26)
        self.assertIn(
            "Packages/Chat/Tests/ChatTests/UI/Snapshots/__Snapshots__/SettingsSheetSnapshotTests/"
            "appleModelRegistration-state-theme.apple_ios26_vellumLight_default.png", additions
        )
        self.assertIn(
            "Packages/Chat/Tests/ChatTests/UI/Snapshots/__Snapshots__/SettingsSheetSnapshotTests/"
            "appleModelRegistrationXXL-state-theme.apple_quota_vellumDark_xxl.png", additions
        )
        settings = {path for path, item in additions.items() if item["suite"] == "SettingsSheetSnapshotTests"}
        self.assertEqual(len(settings), 22)
        self.assertEqual(sum("_default.png" in path for path in settings), 14)
        self.assertEqual(sum("_xxl.png" in path for path in settings), 8)
        composer_directory = "Packages/Chat/Tests/ChatTests/UI/Snapshots/__Snapshots__/ChatComposerSnapshotTests/"
        self.assertEqual(set(additions) - settings, {
            composer_directory + "privateCloudComputeLight.composer_pcc_unresolved_light.png",
            composer_directory + "privateCloudComputeDark.composer_pcc_unresolved_dark.png",
            composer_directory + "privateCloudComputeLightXXL.composer_pcc_unresolved_light_xxl.png",
            composer_directory + "privateCloudComputeDarkXXL.composer_pcc_unresolved_dark_xxl.png",
        })

    def missing_reference_fixture(self):
        message = ("apple_ios26_vellumLight_default: No reference was found on disk. "
                   "New snapshot was not recorded because recording is disabled")
        reports = self.fixture(1, message)
        reports[1]["testNodes"][0]["nodeIdentifier"] = "SettingsSheetSnapshotTests/appleModelRegistration(state:theme:)"
        reports[2]["issues"]["testFailureSummaries"]["_values"][0]["testCaseName"] = {
            "_value": "SettingsSheetSnapshotTests.appleModelRegistration(state:theme:)"
        }
        return reports

    def test_pcc_original_allows_only_approved_missing_reference(self):
        reports = self.missing_reference_fixture()
        additions = migration.approved_additions("Chat", "pcc-registration")
        migration.validate_report(*reports, 65, "original", ["SettingsSheetSnapshotTests"], additions)
        with self.assertRaises(migration.MigrationError):
            migration.validate_report(*reports, 65, "original", ["SettingsSheetSnapshotTests"])

    def test_pcc_original_normalizes_exact_swift_testing_issue_prefix(self):
        reports = self.missing_reference_fixture()
        issue = reports[2]["issues"]["testFailureSummaries"]["_values"][0]
        issue["message"]["_value"] = "Issue recorded: " + issue["message"]["_value"]
        reports[0]["testFailures"] = [{
            "failureText": issue["message"]["_value"],
            "testIdentifierString": "SettingsSheetSnapshotTests/appleModelRegistration(state:theme:)",
        }]
        migration.validate_report(*reports, 65, "original", ["SettingsSheetSnapshotTests"],
                                  migration.approved_additions("Chat", "pcc-registration"))

    def test_pcc_missing_reference_does_not_normalize_arbitrary_issue_prefix(self):
        reports = self.missing_reference_fixture()
        issue = reports[2]["issues"]["testFailureSummaries"]["_values"][0]
        issue["message"]["_value"] = "Unexpected failure: " + issue["message"]["_value"]
        with self.assertRaises(migration.MigrationError):
            migration.validate_report(*reports, 65, "original", ["SettingsSheetSnapshotTests"],
                                      migration.approved_additions("Chat", "pcc-registration"))

    def test_pcc_original_allows_exact_composer_fixture_attribution(self):
        additions = migration.approved_additions("Chat", "pcc-registration")
        for item in additions.values():
            if item["suite"] != "ChatComposerSnapshotTests":
                continue
            with self.subTest(method=item["method"]):
                message = (f"Issue recorded: {item['name']}: No reference was found on disk. "
                           "New snapshot was not recorded because recording is disabled")
                reports = self.fixture(1, message)
                identifier = f"{item['suite']}/{item['method']}()"
                reports[1]["testNodes"][0]["nodeIdentifier"] = identifier
                issue = reports[2]["issues"]["testFailureSummaries"]["_values"][0]
                issue["testCaseName"] = {"_value": identifier.replace("/", ".")}
                migration.validate_report(*reports, 65, "original", [item["suite"]], additions)
                for incorrect in (
                    identifier.replace(item["method"], "unreviewedComposerMethod"),
                    identifier.replace(item["suite"], "SettingsSheetSnapshotTests"),
                ):
                    issue["testCaseName"]["_value"] = incorrect
                    with self.assertRaises(migration.MigrationError):
                        migration.validate_report(*reports, 65, "original", [item["suite"]], additions)

    def test_pcc_missing_reference_requires_attributed_test_method(self):
        reports = self.missing_reference_fixture()
        reports[2]["issues"]["testFailureSummaries"]["_values"][0]["testCaseName"]["_value"] = "OtherSuite.otherMethod()"
        with self.assertRaises(migration.MigrationError):
            migration.validate_report(*reports, 65, "original", ["SettingsSheetSnapshotTests"],
                                      migration.approved_additions("Chat", "pcc-registration"))

    def test_pcc_additions_do_not_allow_missing_references_in_final_verify(self):
        with self.assertRaises(migration.MigrationError):
            migration.validate_report(*self.missing_reference_fixture(), 65, "verify", ["SettingsSheetSnapshotTests"],
                                      migration.approved_additions("Chat", "pcc-registration"))

    def test_pcc_does_not_approve_missing_unlisted_variant(self):
        reports = self.missing_reference_fixture()
        reports[2]["issues"]["testFailureSummaries"]["_values"][0]["message"]["_value"] = (
            "apple_ios26_lapisLight_default: No reference was found on disk. "
            "New snapshot was not recorded because recording is disabled"
        )
        with self.assertRaises(migration.MigrationError):
            migration.validate_report(*reports, 65, "original", ["SettingsSheetSnapshotTests"],
                                      migration.approved_additions("Chat", "pcc-registration"))


if __name__ == "__main__":
    unittest.main()
