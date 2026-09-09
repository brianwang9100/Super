"""Fail-closed package-only coverage parsing, independent of Xcode or live tests."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("swift_coverage", Path(__file__).parents[1] / "swift_coverage.py")
coverage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(coverage)


class SwiftCoverageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.package = Path(self.temporary.name).resolve() / "Packages" / "Chat"
        self.package.mkdir(parents=True)

    def source(self, filename="Sources/Chat/Example.swift", covered=6, count=10):
        return {"filename": str(self.package / filename),
                "summary": {"lines": {"count": count, "covered": covered}}}

    def report(self, *files):
        return {"type": "llvm.coverage.json.export", "data": [{"files": list(files)}]}

    def test_own_package_only_excludes_core_tests_and_build_dependencies(self):
        report = self.report(
            self.source(), self.source("../Core/Sources/Core/Provider.swift", 100, 100),
            self.source("Tests/ChatTests/Test.swift", 100, 100),
            self.source(".build/checkouts/library/Sources/Library.swift", 100, 100),
            self.source("Sources/Chat/.build/generated.swift", 100, 100),
            self.source("Sources/Chat/Tests/generated.swift", 100, 100),
        )
        summary = coverage.summarize(report, self.package)
        self.assertEqual((summary["covered"], summary["count"]), (6, 10))
        self.assertEqual(list(summary["files"]), ["Sources/Chat/Example.swift"])

    def test_counts_are_aggregated_not_averaged_percentages(self):
        summary = coverage.summarize(self.report(self.source(covered=0, count=1),
                                               self.source("Sources/Chat/Other.swift", 99, 99)), self.package)
        self.assertEqual((summary["covered"], summary["count"]), (99, 100))

    def test_relative_source_filename(self):
        source = self.source()
        source["filename"] = "Sources/Chat/Example.swift"
        self.assertEqual(coverage.summarize(self.report(source), self.package)["covered"], 6)

    def test_zero_percent_is_valid_coverage(self):
        self.assertEqual(coverage.summarize(self.report(self.source(covered=0)), self.package)["covered"], 0)

    def test_duplicate_resolved_source_fails_even_across_data_entries(self):
        report = self.report(self.source())
        report["data"].append({"files": [self.source("Sources/Chat/../Chat/Example.swift")]})
        with self.assertRaises(coverage.CoverageError):
            coverage.summarize(report, self.package)

    def test_source_symlink_outside_package_is_excluded(self):
        (self.package / "Sources").mkdir()
        external = self.package.parent / "Core"
        external.mkdir()
        (self.package / "Sources" / "Imported").symlink_to(external, target_is_directory=True)
        summary = coverage.summarize(self.report(self.source(), self.source("Sources/Imported/Other.swift")),
                                     self.package)
        self.assertEqual(len(summary["files"]), 1)

    def test_invalid_counts_fail(self):
        for covered, count in ((-1, 10), (11, 10), (0, -1), (True, 10), (1, "10"), (1.0, 10), (None, 10)):
            with self.subTest(covered=covered, count=count), self.assertRaises(coverage.CoverageError):
                coverage.summarize(self.report(self.source(covered=covered, count=count)), self.package)

    def test_empty_or_unmeasurable_sources_fail(self):
        for report in (self.report(), self.report(self.source(count=0, covered=0)),
                       self.report(self.source("../Core/Sources/Core/Provider.swift"))):
            with self.subTest(report=report), self.assertRaises(coverage.CoverageError):
                coverage.summarize(report, self.package)

    def test_invalid_report_structure_fails(self):
        for report in (None, [], {}, {"type": "other", "data": []},
                       {"type": "llvm.coverage.json.export", "data": [None]},
                       {"type": "llvm.coverage.json.export", "data": [{"files": None}]},
                       self.report({}), self.report({"filename": "Sources/Chat/Example.swift"})):
            with self.subTest(report=report), self.assertRaises(coverage.CoverageError):
                coverage.summarize(report, self.package)

    def export_path(self):
        path = self.package / ".build" / "arm64-apple-macosx" / "debug" / "codecov" / "Chat.json"
        path.parent.mkdir(parents=True)
        path.write_text("{}")
        return path

    def test_authoritative_export_path_accepts_raw_or_labeled_single_path(self):
        path = self.export_path()
        for output in (str(path) + "\n", f"Json: {path}\n", str(path.relative_to(self.package))):
            with self.subTest(output=output):
                self.assertEqual(coverage.report_path(output, self.package), path)

    def test_ambiguous_or_unknown_path_output_fails(self):
        path = self.export_path()
        for output in ("", f"{path}\n{path}", f"warning: unexpected\n{path}", "{}", "some-file.profdata"):
            with self.subTest(output=output), self.assertRaises(coverage.CoverageError):
                coverage.report_path(output, self.package)

    def test_missing_report_fails(self):
        with self.assertRaises(coverage.CoverageError):
            coverage.report_path(str(self.package / ".build" / "missing.json"), self.package)

    def test_report_outside_package_build_fails(self):
        outside = self.package / "other.json"
        outside.write_text("{}")
        with self.assertRaises(coverage.CoverageError):
            coverage.report_path(str(outside), self.package)

    def test_corrupt_report_does_not_echo_payload(self):
        path = self.export_path()
        path.write_text("{sensitive-payload}")
        with self.assertRaisesRegex(coverage.CoverageError, "Cannot read the exported coverage JSON") as caught:
            coverage.read_summary(path, self.package)
        self.assertNotIn("sensitive-payload", str(caught.exception))

    def test_failure_inventory_is_bounded_and_does_not_read_artifacts(self):
        path = self.export_path()
        path.write_text("sensitive-payload")
        (path.parent / "default.profdata").write_text("sensitive-profile")
        paths, omitted = coverage.artifact_inventory(self.package, limit=1)
        self.assertEqual(len(paths), 1)
        self.assertEqual(omitted, 1)
        self.assertTrue(paths[0].startswith(".build/"))
        self.assertNotIn("sensitive", paths[0])


if __name__ == "__main__":
    unittest.main()
