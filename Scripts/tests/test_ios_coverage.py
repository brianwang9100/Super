"""Same-run source coverage, complete-suite safeguards, and unchanged floors."""

import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("ios_coverage", Path(__file__).parents[1] / "ios_coverage.py")
coverage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(coverage)


class IOSCoverageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.workspace = Path(self.temporary.name).resolve()
        self.filename = "Packages/Chat/Sources/Chat/Example.swift"
        path = self.workspace / self.filename
        path.parent.mkdir(parents=True)
        path.write_text("// fixture\n" * 12)
        self.inventory = coverage.source_inventory(self.workspace, "Chat", [self.filename])

    def archive(self, covered=7, executable=10, filename=None):
        return {str(self.workspace / (filename or self.filename)): [
            {"line": index + 1, "isExecutable": True, "executionCount": 4 if index < covered else 0}
            for index in range(executable)
        ]}

    def report(self, *filenames):
        return {"targets": [{"name": "ChatTests", "files": [
            {"path": str(self.workspace / filename), "coveredLines": 900, "executableLines": 1000}
            for filename in filenames or (self.filename,)
        ]}]}

    def summarize(self, archive=None, report=None, inventory=None):
        return coverage.summarize(archive or self.archive(), report or self.report(),
                                  self.workspace, "Chat", inventory or self.inventory)

    def test_each_physical_line_is_counted_once_not_report_instantiation_counts(self):
        result = self.summarize()
        self.assertEqual((result["covered"], result["executable"]), (7, 10))
        self.assertEqual(result["files"][self.filename]["covered"], list(range(1, 8)))
        self.assertTrue(result["meets_threshold"])

    def test_source_only_excludes_tests_other_packages_and_generated_outputs(self):
        archive = self.archive()
        unrelated = ("Packages/Chat/Tests/ChatTests/Test.swift", "Packages/Core/Sources/Core/Provider.swift",
                     "build/derived/SourcePackages/checkouts/Library/Source.swift")
        for filename in unrelated:
            archive.update(self.archive(covered=10, filename=filename))
        result = self.summarize(archive, self.report(self.filename, *unrelated))
        self.assertEqual((result["covered"], result["executable"]), (7, 10))

    def test_no_extra_exclusions_inside_sources(self):
        filename = "Packages/Chat/Sources/Chat/Tests/Production.swift"
        path = self.workspace / filename
        path.parent.mkdir(parents=True)
        path.write_text("// fixture\n" * 12)
        inventory = coverage.source_inventory(self.workspace, "Chat", [filename])
        result = self.summarize(self.archive(filename=filename), self.report(filename), inventory)
        self.assertEqual((result["covered"], result["executable"]), (7, 10))

    def test_all_tracked_sources_are_hashed_and_uncompiled_sources_disclosed(self):
        declaration = "Packages/Chat/Sources/Chat/Declaration.swift"
        (self.workspace / declaration).write_text("protocol Declaration {}\n")
        inventory = coverage.source_inventory(self.workspace, "Chat", [self.filename, declaration])
        result = self.summarize(inventory=inventory)
        self.assertEqual(result["sources_without_coverage_record"], [declaration])
        self.assertEqual(len(inventory[declaration]["sha256"]), 64)
        (self.workspace / declaration).write_text("protocol ChangedDeclaration {}\n")
        self.assertNotEqual(coverage.source_inventory(self.workspace, "Chat", [self.filename, declaration]), inventory)

    def test_core_and_applet_floors_are_unchanged_and_cannot_be_overridden(self):
        self.assertEqual(coverage.threshold("Core"), 80)
        for scheme in ("Chat", "Bible", "Todo", "FutureApplet"):
            self.assertEqual(coverage.threshold(scheme), 70)
        for scheme in ("", "../Core", "Chat; ignored", "/tmp/Chat"):
            with self.subTest(scheme=scheme), self.assertRaises(coverage.CoverageError):
                coverage.threshold(scheme)

    def test_threshold_comparison_does_not_round_a_failure_up(self):
        inventory = {self.filename: {**self.inventory[self.filename], "line_count": 100001}}
        result = self.summarize(self.archive(covered=69999, executable=100000), inventory=inventory)
        self.assertEqual(f"{result['percentage']:.2f}", "70.00")
        self.assertFalse(result["meets_threshold"])
        self.assertTrue(self.summarize(self.archive(covered=7))["meets_threshold"])

    def test_zero_coverage_is_a_valid_failure_not_missing_evidence(self):
        result = self.summarize(self.archive(covered=0))
        self.assertEqual(result["percentage"], 0)
        self.assertFalse(result["meets_threshold"])

    def test_duplicate_source_aliases_or_physical_lines_fail(self):
        archive = self.archive()
        archive[str(self.workspace / "Packages/Chat/Sources/Chat/../Chat/Example.swift")] = next(iter(archive.values()))
        with self.assertRaises(coverage.CoverageError):
            self.summarize(archive)
        archive = self.archive()
        next(iter(archive.values())).append({"line": 1, "isExecutable": True, "executionCount": 10})
        with self.assertRaises(coverage.CoverageError):
            self.summarize(archive)

    def test_invalid_execution_markers_and_counts_fail(self):
        for value in (None, -1, True, "1", 1.5):
            archive = self.archive()
            next(iter(archive.values()))[0]["executionCount"] = value
            with self.subTest(value=value), self.assertRaises(coverage.CoverageError):
                self.summarize(archive)
        for number in (0, -1, True, 100, "1"):
            archive = self.archive()
            next(iter(archive.values()))[0]["line"] = number
            with self.subTest(number=number), self.assertRaises(coverage.CoverageError):
                self.summarize(archive)
        archive = self.archive()
        next(iter(archive.values()))[0]["isExecutable"] = "true"
        with self.assertRaises(coverage.CoverageError):
            self.summarize(archive)

    def test_non_executable_lines_do_not_need_execution_counts(self):
        archive = self.archive()
        next(iter(archive.values())).append({"line": 11, "isExecutable": False})
        self.assertEqual(self.summarize(archive)["executable"], 10)

    def test_empty_unknown_or_inconsistent_source_inventory_fails(self):
        for archive, report in (({}, self.report()), (self.archive(), {"targets": []}),
                                (self.archive(filename="Packages/Chat/Sources/Chat/Unknown.swift"), self.report())):
            with self.subTest(archive=archive), self.assertRaises(coverage.CoverageError):
                coverage.summarize(archive, report, self.workspace, "Chat", self.inventory)
        with self.assertRaises(coverage.CoverageError):
            self.summarize(self.archive(executable=0))

    def test_source_symlinks_and_missing_source_files_fail_closed(self):
        outside = self.workspace / "external.swift"
        outside.write_text("// fixture\n")
        linked = self.workspace / "Packages/Chat/Sources/Chat/Linked.swift"
        linked.symlink_to(outside)
        for names in ((str(linked.relative_to(self.workspace)),), ("Packages/Chat/Sources/Chat/Missing.swift",)):
            with self.subTest(names=names), self.assertRaises(coverage.CoverageError):
                coverage.source_inventory(self.workspace, "Chat", names)
        with self.assertRaises(coverage.CoverageError):
            coverage.source_key(str(linked), self.workspace, "Chat")

    def scheme(self):
        return ('<Scheme><TestAction onlyGenerateCoverageForSpecifiedTargets="NO"><Testables>'
                '<TestableReference skipped="NO"><BuildableReference BlueprintName="ChatTests"/>'
                '</TestableReference></Testables></TestAction></Scheme>')

    def test_full_scheme_rejects_test_and_source_filters(self):
        coverage.validate_scheme(self.scheme(), "Chat")
        for tag in ("TestPlans", "SkippedTests", "SelectedTests", "CodeCoverageTargets"):
            xml = self.scheme().replace("</TestAction>", f"<{tag}/></TestAction>")
            with self.subTest(tag=tag), self.assertRaises(coverage.CoverageError):
                coverage.validate_scheme(xml, "Chat")
        for xml in (self.scheme().replace('skipped="NO"', 'skipped="YES"'),
                    self.scheme().replace("ChatTests", "CoreTests"),
                    self.scheme().replace('Targets="NO"', 'Targets="YES"')):
            with self.subTest(xml=xml), self.assertRaises(coverage.CoverageError):
                coverage.validate_scheme(xml, "Chat")

    def test_enumeration_rejects_missing_duplicate_disabled_and_foreign_tests(self):
        valid = {"errors": [], "values": [{"enabledTests": [{"identifier": "ChatTests/Suite/runs()"}],
                                          "disabledTests": []}]}
        self.assertEqual(coverage.expected_tests(valid, "Chat"), ["Suite/runs()"])
        for variant in ({}, {"errors": ["failed"], "values": []},
                        {"errors": [], "values": [{"enabledTests": [], "disabledTests": []}]}):
            with self.assertRaises(coverage.CoverageError):
                coverage.expected_tests(variant, "Chat")
        for identifier in ("ChatTests/Suite/runs()", "OtherTests/Suite/extra()"):
            variant = json.loads(json.dumps(valid))
            variant["values"][0]["enabledTests"].append({"identifier": identifier})
            with self.assertRaises(coverage.CoverageError):
                coverage.expected_tests(variant, "Chat")
        valid["values"][0]["disabledTests"] = [{"identifier": "ChatTests/Suite/disabled()"}]
        with self.assertRaises(coverage.CoverageError):
            coverage.expected_tests(valid, "Chat")

    def execution(self):
        return ({"totalTestCount": 2, "passedTests": 1, "failedTests": 0, "skippedTests": 1,
                 "expectedFailures": 0, "result": "Passed", "testFailures": []},
                {"nodes": [{"nodeType": "Test Case", "nodeIdentifier": "Suite/runs()", "result": "Passed"},
                           {"nodeType": "Test Case", "nodeIdentifier": "Suite/unsupportedPlatform()", "result": "Skipped"}]},
                {})

    def test_successful_execution_discloses_exact_counts_and_skips(self):
        result = coverage.execution_summary(*self.execution(), 0, False)
        self.assertEqual((result["totalTestCount"], result["passedTests"], result["skippedTests"]), (2, 1, 1))
        self.assertEqual(result["skipped_identifiers"], ["Suite/unsupportedPlatform()"])
        self.assertEqual((result["individual_run_count"], result["individual_skipped_count"]), (2, 1))

    def test_parameterized_functions_and_individual_runs_are_counted_separately(self):
        summary, tree, legacy = self.execution()
        tree["nodes"][0]["children"] = [
            {"nodeType": "Arguments", "nodeIdentifierURL": f"test://Suite/runs?args={index}", "result": "Passed"}
            for index in range(3)]
        result = coverage.execution_summary(summary, tree, legacy, 0, False)
        self.assertEqual((result["totalTestCount"], result["individual_run_count"]), (2, 4))
        self.assertEqual(len(result["individual_runs"]), 4)
        for state in ("Failed", "Running"):
            tree["nodes"][0]["children"][0]["result"] = state
            with self.subTest(state=state), self.assertRaises(coverage.CoverageError):
                coverage.execution_summary(summary, tree, legacy, 0, False)

    def test_tree_and_summary_count_mismatches_fail_closed(self):
        summary, tree, legacy = self.execution()
        tree["nodes"].append({"nodeType": "Test Case", "nodeIdentifier": "Suite/unreported()", "result": "Passed"})
        with self.assertRaises(coverage.CoverageError):
            coverage.execution_summary(summary, tree, legacy, 0, False)
        summary, tree, legacy = self.execution()
        tree["nodes"][1]["result"] = "Passed"
        with self.assertRaises(coverage.CoverageError):
            coverage.execution_summary(summary, tree, legacy, 0, False)

    def test_workflow_keeps_one_required_gate_with_capture_and_coverage_dependencies(self):
        root = Path(__file__).parents[2]
        workflow = (root / ".github/workflows/argos.yml").read_text()
        self.assertIn("python3 Scripts/ios_coverage.py --evidence", workflow)
        self.assertIn("needs: [discover, capture-package, coverage]", workflow)
        self.assertIn('test "$COVERAGE" = success', workflow)
        self.assertIn("run-${{ matrix.package }}-*/coverage/", workflow)
        self.assertIn("if: always()", workflow)
        self.assertNotIn("continue-on-error", workflow)
        owners = [path.name for path in (root / ".github/workflows").glob("*.yml")
                  if "\n  ios-test:" in path.read_text()]
        self.assertEqual(owners, ["argos.yml"])

    def test_failed_incomplete_or_empty_execution_cannot_establish_coverage(self):
        for field, value in (("totalTestCount", 0), ("totalTestCount", 10), ("passedTests", 0),
                             ("expectedFailures", 1), ("result", "Failed"), ("failedTests", 1),
                             ("testFailures", [{"failureText": "fixture failure"}])):
            summary, tree, legacy = self.execution()
            summary[field] = value
            with self.subTest(field=field), self.assertRaises(coverage.CoverageError):
                coverage.execution_summary(summary, tree, legacy, 0, False)
        for exit_code, timed_out in ((65, False), (0, True)):
            with self.subTest(exit_code=exit_code), self.assertRaises(coverage.CoverageError):
                coverage.execution_summary(*self.execution(), exit_code, timed_out)

    def test_hidden_build_errors_or_failed_test_cases_fail_closed(self):
        for category in ("errorSummaries", "testFailureSummaries"):
            summary, tree, legacy = self.execution()
            legacy["issues"] = {category: {"_values": [{"message": {"_value": "fixture"}}]}}
            with self.subTest(category=category), self.assertRaises(coverage.CoverageError):
                coverage.execution_summary(summary, tree, legacy, 0, False)
        summary, tree, legacy = self.execution()
        tree["nodes"][0]["result"] = "Failed"
        with self.assertRaises(coverage.CoverageError):
            coverage.execution_summary(summary, tree, legacy, 0, False)

    def test_missing_duplicate_or_incomplete_test_identifiers_fail(self):
        for identifier, result in (("", "Passed"), ("Suite/unsupportedPlatform()", "Passed"),
                                   ("Suite/runs()", "Running")):
            summary, tree, legacy = self.execution()
            tree["nodes"][0].update(nodeIdentifier=identifier, result=result)
            with self.subTest(identifier=identifier), self.assertRaises(coverage.CoverageError):
                coverage.execution_summary(summary, tree, legacy, 0, False)

    def evidence(self, visual_covered=4, logic_covered=7):
        output = Path(self.temporary.name) / "evidence"
        output.mkdir()
        invocation = {"sha": "same-source", "run_id": "42", "run_attempt": "1"}
        options = ["-scheme", "Chat", "-derivedDataPath", "/same-build", "-enableCodeCoverage", "YES"]
        coverage.write_json(output / "provenance.json", {
            "scheme": "Chat", "identity": invocation, "workspace": str(self.workspace),
            "source_hashes": self.inventory, "input_hashes": {self.filename: self.inventory[self.filename]["sha256"]},
            "suites": ["Visual"], "build_products": {"test.xctestrun": "build-hash"},
            "test_options": options, "completed": True,
        })
        coverage.write_json(output / "enumeration.json", {"errors": [], "values": [{
            "disabledTests": [], "enabledTests": [{"identifier": "ChatTests/" + name}
                for name in ("Visual/renders()", "Logic/runs()", "Logic/skipped()")]}]})
        for leg, covered in (("Visual", visual_covered), ("logic", logic_covered)):
            folder = output / leg
            folder.mkdir()
            summary = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0,
                       "skippedTests": 0, "expectedFailures": 0, "result": "Passed", "testFailures": []}
            tree = {"nodes": [{"nodeType": "Test Case", "nodeIdentifier":
                              "Visual/renders()" if leg == "Visual" else "Logic/runs()", "result": "Passed"}]}
            if leg == "logic":
                tree["nodes"].append({"nodeType": "Test Case", "nodeIdentifier": "Logic/skipped()", "result": "Skipped"})
                summary.update(totalTestCount=2, skippedTests=1)
            selection = (["-only-testing:ChatTests", "-skip-testing:ChatTests/Visual"]
                         if leg == "logic" else ["-only-testing:ChatTests/Visual"])
            for name, value in {
                "summary": summary, "tests": tree, "issues": {},
                "coverage-report": self.report(), "coverage-archive": self.archive(covered=covered),
                "process": {"command": ["xcodebuild", "test-without-building", *options, *selection,
                                       "-resultBundlePath", leg + ".xcresult"],
                            "bundle": leg + ".xcresult", "exit_code": 0, "timed_out": False},
            }.items():
                coverage.write_json(folder / (name + ".json"), value)
        return output, invocation

    def test_actual_repository_inputs_round_trip_capture_and_audit(self):
        # Use the actual tracked tree, including package CLAUDE.md aliases. A
        # synthetic all-regular-file inventory concealed the capture/audit mismatch.
        self.workspace = Path(__file__).resolve().parents[2]
        self.filename = "Packages/Chat/Sources/Chat/ViewModels/SettingsViewModel.swift"
        self.inventory = coverage.source_inventory(self.workspace, "Chat", [self.filename])
        inputs = coverage.command("git", "-C", str(self.workspace), "ls-files", "-z", "--", "Packages", "project.yml",
                                  "Scripts/xcodegen-extras").strip("\0").split("\0")
        capture = SimpleNamespace(workspace=self.workspace, inputs=inputs)
        hashes = coverage.CaptureCoverage.hash_inputs(capture)
        aliases = {f"Packages/{package}/CLAUDE.md" for package in ("Bible", "Chat", "Core", "Todo")}
        self.assertEqual(set(hashes), set(inputs) - aliases)
        output, invocation = self.evidence()
        provenance = json.loads((output / "provenance.json").read_text())
        coverage.write_json(output / "provenance.json", {**provenance, "input_hashes": hashes})
        self.assertTrue(coverage.audit_evidence(output, self.workspace, invocation)["meets_threshold"])

    def test_capture_and_audit_reject_unsafe_build_inputs(self):
        target = self.workspace / self.filename
        linked = target.with_name("Linked.swift")
        linked.symlink_to(target)
        directory = self.workspace / "linked-sources"
        directory.symlink_to(target.parent, target_is_directory=True)
        instruction = self.workspace / "Packages/Chat/Sources/Chat/CLAUDE.md"
        instruction.symlink_to(target)
        alias = self.workspace / "Packages/Chat/CLAUDE.md"
        alias.symlink_to(target)  # Only an exact package-root AGENTS.md alias is exempt.
        escaping = target.with_name("Escape.swift")
        escaping.symlink_to("/etc/hosts")
        names = [str(linked.relative_to(self.workspace)), str(instruction.relative_to(self.workspace)),
                 "linked-sources/Example.swift", "Packages/Chat/CLAUDE.md",
                 str(escaping.relative_to(self.workspace)), str(target),
                 "Packages/Chat/Sources/Chat/../Chat/Example.swift", "../outside.swift"]
        output, invocation = self.evidence()
        provenance = json.loads((output / "provenance.json").read_text())
        for name in names:
            with self.subTest(name=name, phase="capture"), self.assertRaises(coverage.CoverageError):
                coverage.CaptureCoverage.hash_inputs(SimpleNamespace(workspace=self.workspace, inputs=[name]))
            coverage.write_json(output / "provenance.json", {
                **provenance, "input_hashes": {name: self.inventory[self.filename]["sha256"]}})
            with self.subTest(name=name, phase="audit"), self.assertRaises(coverage.CoverageError):
                coverage.audit_evidence(output, self.workspace, invocation)

    def test_raw_evidence_recomputes_union_without_averaging_percentages(self):
        output, invocation = self.evidence()
        result = coverage.audit_evidence(output, self.workspace, invocation)
        self.assertEqual((result["covered"], result["executable"]), (7, 10))
        self.assertTrue(result["meets_threshold"])
        execution = json.loads((output / "execution.json").read_text())
        self.assertEqual(execution["totalTestCount"], 3)
        self.assertEqual(execution["skipped_identifiers"], ["Logic/skipped()"])

    def test_below_floor_capture_retains_result_but_gate_fails(self):
        output, invocation = self.evidence(logic_covered=6)
        result = coverage.audit_evidence(output, self.workspace, invocation, enforce_floor=False)
        self.assertFalse(result["meets_threshold"])
        with self.assertRaisesRegex(coverage.CoverageError, "unchanged 70% floor"):
            coverage.audit_evidence(output, self.workspace, invocation)
        self.assertTrue((output / "coverage-summary.json").is_file())

    def test_mismatched_run_source_build_or_incomplete_result_is_rejected(self):
        output, invocation = self.evidence()
        provenance_path = output / "provenance.json"
        original = json.loads(provenance_path.read_text())
        for key, value in (("identity", {}), ("source_hashes", {}),
                           ("build_products", {}), ("completed", False), ("test_options", ["other-build"])):
            coverage.write_json(provenance_path, {**original, key: value})
            with self.subTest(key=key), self.assertRaises(coverage.CoverageError):
                coverage.audit_evidence(output, self.workspace, invocation)
        coverage.write_json(provenance_path, original)
        (self.workspace / self.filename).write_text("// changed\n")
        with self.assertRaises(coverage.CoverageError):
            coverage.audit_evidence(output, self.workspace, invocation)

    def test_missing_or_duplicate_union_and_wrong_ownership_fail_closed(self):
        executions = {
            "Visual": {"test_identifiers": ["Visual/render()"], "individual_runs": [], "skipped_identifiers": []},
            "logic": {"test_identifiers": ["Logic/run()"], "individual_runs": [], "skipped_identifiers": []},
        }
        expected = ["Visual/render()", "Logic/run()"]
        coverage.validate_execution_union(executions, expected, ["Visual"])
        with self.assertRaises(coverage.CoverageError):
            coverage.validate_execution_union(executions, expected + ["Logic/missing()"], ["Visual"])
        executions["logic"]["test_identifiers"].append("Visual/render()")
        with self.assertRaises(coverage.CoverageError):
            coverage.validate_execution_union(executions, expected, ["Visual"])

    def test_mismatched_executable_denominator_fails_closed(self):
        one = self.summarize(self.archive(covered=4))
        two = self.summarize(self.archive(covered=7, executable=11))
        with self.assertRaises(coverage.CoverageError):
            coverage.merge_measurements([one, two])

    def test_complementary_hits_are_unioned_once(self):
        one = self.summarize(self.archive(covered=4))
        archive = self.archive(covered=0)
        for line in next(iter(archive.values()))[3:7]:
            line["executionCount"] = 1
        two = self.summarize(archive)
        result = coverage.merge_measurements([one, two])
        self.assertEqual((result["covered"], result["executable"]), (7, 10))

    def test_failed_execution_retains_raw_reports_but_cannot_pass(self):
        output, invocation = self.evidence()
        process_path = output / "logic/process.json"
        process = json.loads(process_path.read_text())
        coverage.write_json(process_path, {**process, "exit_code": 65})
        with self.assertRaises(coverage.CoverageError):
            coverage.audit_evidence(output, self.workspace, invocation)
        self.assertTrue((output / "logic/coverage-archive.json").is_file())
        self.assertFalse((output / "coverage-summary.json").exists())


if __name__ == "__main__":
    unittest.main()
