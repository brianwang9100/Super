#!/usr/bin/env python3
"""Audit complete, serialized iOS test evidence and gate physical source lines."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import xml.etree.ElementTree as ET


class CoverageError(RuntimeError):
    """Coverage evidence cannot establish a successful, complete measurement."""


def require(condition, message):
    if not condition:
        raise CoverageError(message)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def command(*arguments):
    return subprocess.check_output(arguments, text=True, timeout=120)


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def threshold(scheme):
    require(re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", scheme), "Invalid package scheme")
    return 80 if scheme == "Core" else 70


def source_inventory(workspace, scheme, tracked):
    """Hash every tracked file under Sources, including non-instrumented files."""
    root = workspace / "Packages" / scheme / "Sources"
    inventory = {}
    for name in tracked:
        path = workspace / name
        require(path.is_relative_to(root) and path.is_file() and not path.is_symlink(),
                "Tracked source inventory contains a missing or unsafe path")
        require(path.resolve().is_relative_to(root.resolve()), "Source path escapes its package")
        digest = hashlib.sha256()
        line_count = 1
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
                line_count += chunk.count(b"\n")
        inventory[name] = {"sha256": digest.hexdigest(), "line_count": line_count}
    require(inventory, "Empty tracked source inventory")
    return inventory


def source_key(filename, workspace, scheme):
    require(isinstance(filename, str) and filename, "Missing coverage source filename")
    path = Path(filename)
    path = Path(os.path.abspath(path if path.is_absolute() else workspace / path))
    root = workspace / "Packages" / scheme / "Sources"
    if not path.is_relative_to(root):
        return None
    require(path.resolve().is_relative_to(root.resolve()), "Coverage source escapes its package")
    return str(path.resolve().relative_to(workspace))


def summarize(archive, report, workspace, scheme, inventory):
    """Count each physical source line once, not repeated generic instantiations."""
    require(isinstance(archive, dict) and archive, "Empty or invalid xccov line archive")
    require(isinstance(report, dict) and isinstance(report.get("targets"), list), "Invalid xccov report")
    reported = set()
    for target in report["targets"]:
        require(isinstance(target, dict) and isinstance(target.get("files"), list), "Missing coverage file inventory")
        for file in target["files"]:
            require(isinstance(file, dict), "Invalid coverage file")
            key = source_key(file.get("path"), workspace, scheme)
            if key is not None:
                reported.add(key)
    files = {}
    for filename, lines in archive.items():
        key = source_key(filename, workspace, scheme)
        if key is None:
            continue
        require(key in inventory, "Instrumented source is not in this checkout's tracked inventory")
        require(key not in files, "Duplicate resolved source in coverage archive")
        require(isinstance(lines, list), "Missing per-line coverage")
        executable, covered, seen = [], [], set()
        for line in lines:
            require(isinstance(line, dict), "Invalid coverage line")
            number, measurable = line.get("line"), line.get("isExecutable")
            require(type(number) is int and 0 < number <= inventory[key]["line_count"],
                    "Coverage line is outside the hashed source")
            require(number not in seen, "Duplicate physical source line")
            require(type(measurable) is bool, "Invalid executable-line marker")
            seen.add(number)
            if measurable:
                count = line.get("executionCount")
                require(type(count) is int and count >= 0, "Invalid line execution count")
                executable.append(number)
                if count > 0:
                    covered.append(number)
        files[key] = {"executable": executable, "covered": covered}
    require(files and set(files) == reported, "Coverage report/archive source inventories disagree or are empty")
    executable = sum(len(file["executable"]) for file in files.values())
    covered = sum(len(file["covered"]) for file in files.values())
    require(executable > 0, "No executable package source lines measured")
    floor = threshold(scheme)
    return {
        "metric": "Unique physical executable source lines in one full iOS simulator test run",
        "covered": covered, "executable": executable, "percentage": 100 * covered / executable,
        "threshold": floor, "meets_threshold": covered * 100 >= executable * floor,
        "files": files,
        # Platform conditionals, declarations, and resources may have no coverage
        # record. Retain their hashes and disclose the list; never invent misses.
        "sources_without_coverage_record": sorted(set(inventory) - set(files)),
    }


def validate_scheme(xml, scheme):
    """Refuse selective test plans or scheme-level source-coverage exclusions."""
    root = ET.fromstring(xml)
    action = root.find("TestAction")
    require(action is not None, "Scheme has no test action")
    require(action.get("onlyGenerateCoverageForSpecifiedTargets") == "NO", "Scheme restricts coverage targets")
    for tag in ("TestPlans", "SkippedTests", "SelectedTests", "CodeCoverageTargets"):
        require(action.find(".//" + tag) is None, "Scheme selects or excludes tests/coverage")
    testables = action.findall("./Testables/TestableReference")
    require(len(testables) == 1 and testables[0].get("skipped") == "NO", "Expected one enabled full test target")
    reference = testables[0].find("BuildableReference")
    require(reference is not None and reference.get("BlueprintName") == scheme + "Tests",
            "Scheme does not test the requested package")


def run_tests(arguments, environment, log_path):
    """Keep a full build/test log and bound the entire child process group."""
    timed_out = threading.Event()
    with log_path.open("w") as log:
        process = subprocess.Popen(arguments, env=environment, text=True, start_new_session=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

        def expire():
            timed_out.set()
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

        timer = threading.Timer(45 * 60, expire)
        timer.start()
        try:
            for line in process.stdout:
                print(line, end="", flush=True)
                log.write(line)
            status = process.wait(timeout=30)
        finally:
            timer.cancel()
    return status, timed_out.is_set()


def execution_summary(summary, tree, legacy, exit_code, timed_out):
    """Coverage cannot pass a failed, empty, or incomplete test execution."""
    require(type(exit_code) is int and type(timed_out) is bool, "Invalid test-process outcome")
    counts = {name: summary.get(name) for name in
              ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")}
    require(all(type(value) is int and value >= 0 for value in counts.values()), "Invalid test execution counts")
    require(counts["totalTestCount"] > 0 and counts["passedTests"] > 0, "Empty test execution")
    require(counts["totalTestCount"] == counts["passedTests"] + counts["failedTests"] + counts["skippedTests"],
            "Incomplete test execution counts")
    cases = [node for node in walk(tree) if node.get("nodeType") == "Test Case"]
    require(cases and all(node.get("result") in ("Passed", "Failed", "Skipped") for node in cases),
            "Incomplete test case inventory")
    identifiers = [node.get("nodeIdentifier", "") for node in cases]
    require(all(identifiers) and len(set(identifiers)) == len(identifiers), "Missing or duplicate test identifiers")
    require(len(cases) == counts["totalTestCount"], "Test tree and summary totals disagree")
    for field, state in (("passedTests", "Passed"), ("failedTests", "Failed"), ("skippedTests", "Skipped")):
        require(sum(node["result"] == state for node in cases) == counts[field],
                "Test tree and summary outcomes disagree")
    # Summary totals count parameterized functions once. Preserve and report
    # their individual argument runs too, without confusing the two counts.
    runs = []
    for case in cases:
        arguments = [node for node in walk(case.get("children", [])) if node.get("nodeType") == "Arguments"]
        for node in arguments or [case]:
            identifier = node.get("nodeIdentifierURL") if arguments else case["nodeIdentifier"]
            require(isinstance(identifier, str) and identifier, "Missing parameterized-run identity")
            require(node.get("result") in ("Passed", "Skipped"), "Failed or incomplete individual test run")
            runs.append({"identifier": identifier, "result": node["result"]})
    require(len({run["identifier"] for run in runs}) == len(runs), "Duplicate individual test run")
    result = {**counts, "exit_code": exit_code, "timed_out": timed_out,
              "test_identifiers": sorted(identifiers),
              "skipped_identifiers": sorted(node["nodeIdentifier"] for node in cases if node["result"] == "Skipped"),
              "individual_runs": runs, "individual_run_count": len(runs),
              "individual_skipped_count": sum(run["result"] == "Skipped" for run in runs)}
    require(not timed_out and exit_code == 0 and summary.get("result") == "Passed"
            and counts["failedTests"] == 0 and counts["expectedFailures"] == 0
            and not summary.get("testFailures"), "Full simulator test suite did not pass")
    for node in walk(legacy):
        for category in ("errorSummaries", "testFailureSummaries"):
            require(not node.get(category, {}).get("_values"), "Build/test failure in result bundle")
    require(all(node["result"] != "Failed" for node in cases), "Failed test case in result bundle")
    return result


def expected_tests(enumeration, scheme):
    """Read Xcode 27's flat enumeration, including explicitly disabled tests."""
    require(isinstance(enumeration, dict) and enumeration.get("errors") == [],
            "Test enumeration failed or has no error inventory")
    values = enumeration.get("values")
    require(isinstance(values, list) and len(values) == 1, "Expected one enumerated test plan")
    enabled, disabled = [], []
    for field, destination in (("enabledTests", enabled), ("disabledTests", disabled)):
        rows = values[0].get(field)
        require(isinstance(rows, list), "Missing enumerated test inventory")
        for row in rows:
            identifier = row.get("identifier")
            require(isinstance(identifier, str) and identifier.startswith(scheme + "Tests/")
                    and len(identifier.split("/")) >= 3, "Unexpected enumerated test identity")
            destination.append(identifier.removeprefix(scheme + "Tests/"))
    require(enabled and len(set(enabled + disabled)) == len(enabled + disabled),
            "Empty or duplicate enumerated tests")
    # A scheme-level disabled test must not disappear from the execution union.
    # Runtime skips remain allowed and are disclosed by execution_summary.
    require(not disabled, "Scheme disables enumerated tests; full coverage requires their execution evidence")
    return sorted(enabled)


def merge_measurements(measurements):
    """Union raw line hits only when every run has the identical denominator."""
    require(measurements, "Missing coverage measurements")
    first = measurements[0]
    files = {name: {"executable": row["executable"], "covered": set(row["covered"])}
             for name, row in first["files"].items()}
    for measurement in measurements[1:]:
        require(measurement["threshold"] == first["threshold"]
                and set(measurement["files"]) == set(files)
                and measurement["sources_without_coverage_record"] == first["sources_without_coverage_record"],
                "Mismatched coverage source inventories")
        for name, row in measurement["files"].items():
            require(row["executable"] == files[name]["executable"], "Mismatched executable source lines")
            files[name]["covered"].update(row["covered"])
    covered = sum(len(row["covered"]) for row in files.values())
    executable = sum(len(row["executable"]) for row in files.values())
    return {**first, "metric": "Union of physical executable line hits from one build's complete iOS test inventory",
            "files": {name: {**row, "covered": sorted(row["covered"])} for name, row in files.items()},
            "covered": covered, "executable": executable, "percentage": 100 * covered / executable,
            "meets_threshold": covered * 100 >= executable * first["threshold"]}


def validate_execution_union(executions, expected, suites):
    """Every discovered test executes once, in its designated isolated leg."""
    require(set(executions) == set(suites) | {"logic"}, "Missing or unexpected test execution leg")
    all_tests, runs, skips = [], [], []
    for leg, execution in executions.items():
        identifiers = execution["test_identifiers"]
        for identifier in identifiers:
            owner = identifier.split("/")[0]
            require((owner not in suites) if leg == "logic" else owner == leg,
                    "Test executed in the wrong isolated leg")
        all_tests.extend(identifiers)
        runs.extend(execution["individual_runs"])
        skips.extend(execution["skipped_identifiers"])
    require(len(all_tests) == len(set(all_tests)), "Duplicate tests across execution legs")
    require(set(all_tests) == set(expected),
            f"Incomplete test union: missing={sorted(set(expected)-set(all_tests))}, unexpected={sorted(set(all_tests)-set(expected))}")
    require(len(runs) == len({run["identifier"] for run in runs}), "Duplicate parameterized execution across legs")
    return {"test_identifiers": sorted(all_tests), "totalTestCount": len(all_tests),
            "skipped_identifiers": sorted(skips), "individual_runs": runs,
            "individual_run_count": len(runs),
            "individual_skipped_count": sum(run["result"] == "Skipped" for run in runs)}


def build_inventory(derived_data):
    """Bind all test products, resources and xctestrun metadata to one build."""
    products = derived_data / "Build/Products"
    require(products.is_dir(), "Missing instrumented test build products")
    paths = sorted(path for path in products.rglob("*") if path.is_file() and not path.is_symlink())
    require(any(path.suffix == ".xctestrun" for path in paths), "Missing xctestrun build identity")
    result = {}
    for path in paths:
        with path.open("rb") as stream:
            result[str(path.relative_to(products))] = hashlib.file_digest(stream, "sha256").hexdigest()
    return result


def input_hashes(workspace, names):
    """Fingerprint build inputs with the same fail-closed policy at capture and audit."""
    workspace = workspace.resolve()
    hashes = {}
    for name in names:
        require(isinstance(name, str) and name, "Unsafe coverage input path")
        relative = Path(name)
        require(not relative.is_absolute() and ".." not in relative.parts
                and relative.as_posix() == name, "Unsafe coverage input path")
        path = workspace / relative
        # These package-root instruction aliases cannot be compiled or copied as
        # target resources. Their canonical AGENTS.md files remain fingerprinted.
        # Do not exempt a similarly named file inside Sources/Tests/resources.
        if (len(relative.parts) == 3 and relative.parts[0] == "Packages"
                and relative.name == "CLAUDE.md" and path.is_symlink()):
            target = path.with_name("AGENTS.md")
            require(path.readlink() == Path("AGENTS.md") and target.is_file()
                    and target.resolve() == target, "Unsafe coverage instruction alias")
            continue
        require(path.is_file() and not path.is_symlink() and path.resolve() == path,
                "Unsafe coverage input path")
        hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


class CaptureCoverage:
    """Collect visual and logic results without rebuilding or concurrent visual suites."""

    def __init__(self, workspace, scheme, evidence, invocation, environment, suites, derived_data):
        self.workspace, self.scheme, self.evidence = workspace, scheme, evidence
        self.folder = evidence / "coverage"
        self.folder.mkdir()
        self.suites = suites
        self.derived_data = derived_data
        validate_scheme((workspace / "Super.xcodeproj/xcshareddata/xcschemes" / f"{scheme}.xcscheme").read_text(), scheme)
        self.tracked = [name for name in command("git", "ls-files", "-z", "--",
                        f"Packages/{scheme}/Sources").split("\0") if name]
        self.sources = source_inventory(workspace, scheme, self.tracked)
        # Include test sources and shared dependencies so changes while compiling
        # or capturing cannot be attributed to a different source revision.
        inputs = [name for name in command("git", "ls-files", "-z", "--", "Packages", "project.yml",
                                           "Scripts/xcodegen-extras").split("\0") if name]
        self.inputs = inputs
        self.input_hashes = self.hash_inputs()
        self.provenance = {"identity": invocation, "scheme": scheme, "workspace": str(workspace),
                           "environment": environment, "source_hashes": self.sources,
                           "input_hashes": self.input_hashes, "suites": suites}
        write_json(self.folder / "provenance.json", self.provenance)

    def hash_inputs(self):
        return input_hashes(self.workspace, self.inputs)

    def prepare(self, options):
        require(self.hash_inputs() == self.input_hashes, "Sources changed during instrumented build")
        self.products = build_inventory(self.derived_data)
        self.provenance["build_products"] = self.products
        self.provenance["test_options"] = options
        write_json(self.folder / "provenance.json", self.provenance)
        enumeration_path = self.folder / "enumeration.json"
        arguments = ["xcodebuild", "test-without-building", *options, "-enumerate-tests",
                     "-test-enumeration-format", "json", "-test-enumeration-style", "flat",
                     "-test-enumeration-output-path", str(enumeration_path)]
        with (self.folder / "enumeration.log").open("w") as log:
            subprocess.run(arguments, cwd=self.workspace, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=900)
        enumeration = json.loads(enumeration_path.read_text())
        expected_tests(enumeration, self.scheme)

    def collect(self, leg, bundle, arguments, exit_code=0, timed_out=False):
        folder = self.folder / leg
        folder.mkdir()
        write_json(folder / "process.json", {"command": arguments, "bundle": str(bundle),
                   "exit_code": exit_code, "timed_out": timed_out})
        require(bundle.is_dir(), "Test process produced no result bundle")
        # Preserve all raw reports before judging execution, including failures.
        for name, tool_arguments in (
            ("summary", ("xcresulttool", "get", "test-results", "summary", "--path")),
            ("tests", ("xcresulttool", "get", "test-results", "tests", "--path")),
            ("issues", ("xcresulttool", "get", "object", "--legacy", "--format", "json", "--path")),
            ("coverage-report", ("xccov", "view", "--report", "--json")),
            ("coverage-archive", ("xccov", "view", "--archive", "--json")),
        ):
            write_json(folder / f"{name}.json", json.loads(command("xcrun", *tool_arguments, str(bundle))))

    def finish(self, options, environment):
        bundle = self.evidence / "logic.xcresult"
        arguments = ["xcodebuild", "test-without-building", *options,
                     f"-only-testing:{self.scheme}Tests",
                     *[f"-skip-testing:{self.scheme}Tests/{suite}" for suite in self.suites],
                     "-resultBundlePath", str(bundle)]
        exit_code, timed_out = run_tests(arguments, environment, self.evidence / "logic.log")
        self.collect("logic", bundle, arguments, exit_code, timed_out)
        require(self.hash_inputs() == self.input_hashes, "Sources changed during test execution")
        require(build_inventory(self.derived_data) == self.products, "Instrumented build products changed during tests")
        self.provenance["completed"] = True
        write_json(self.folder / "provenance.json", self.provenance)
        return audit_evidence(self.folder, self.workspace, self.provenance["identity"], enforce_floor=False)


def audit_evidence(folder, workspace, invocation, enforce_floor=True):
    """Recompute the gate from this run's raw artifacts, never a percentage sum."""
    provenance = json.loads((folder / "provenance.json").read_text())
    require(provenance["identity"] == invocation, "Coverage belongs to another revision or run")
    scheme = provenance["scheme"]
    threshold(scheme)
    require(source_inventory(workspace, scheme, provenance["source_hashes"]) == provenance["source_hashes"],
            "Coverage source hashes do not match the checkout")
    require(provenance.get("build_products"), "Missing same-build identity")
    require(provenance.get("completed") is True, "Capture did not verify final source/build identity")
    require(input_hashes(workspace, provenance["input_hashes"]) == provenance["input_hashes"],
            "Test/build inputs do not match checkout")
    expected = expected_tests(json.loads((folder / "enumeration.json").read_text()), scheme)
    suites = provenance["suites"]
    require(isinstance(suites, list) and len(suites) == len(set(suites)) and suites,
            "Missing or duplicate serialized suite owners")
    require({p.name for p in folder.iterdir() if p.is_dir()} == set(suites) | {"logic"},
            "Missing or unexpected result evidence")
    executions, measurements = {}, []
    for leg in [*suites, "logic"]:
        raw = {name: json.loads((folder / leg / f"{name}.json").read_text()) for name in
               ("summary", "tests", "issues", "coverage-report", "coverage-archive", "process")}
        process = raw["process"]
        selection = ([f"-only-testing:{scheme}Tests", *[f"-skip-testing:{scheme}Tests/{suite}" for suite in suites]]
                     if leg == "logic" else [f"-only-testing:{scheme}Tests/{leg}"])
        require(process["command"] == ["xcodebuild", "test-without-building", *provenance["test_options"],
                *selection, "-resultBundlePath", process["bundle"]], "Result uses a different build or test selection")
        executions[leg] = execution_summary(raw["summary"], raw["tests"], raw["issues"],
                                            process["exit_code"], process["timed_out"])
        measurements.append(summarize(raw["coverage-archive"], raw["coverage-report"],
                            Path(provenance["workspace"]), scheme, provenance["source_hashes"]))
    execution = validate_execution_union(executions, expected, suites)
    coverage = merge_measurements(measurements)
    write_json(folder / "execution.json", execution)
    write_json(folder / "coverage-summary.json", coverage)
    print(f"{scheme}: {coverage['percentage']:.2f}% ({coverage['covered']}/{coverage['executable']} physical lines), "
          f"floor {coverage['threshold']}%; {execution['totalTestCount']} test functions, "
          f"{execution['individual_run_count']} parameterized executions, "
          f"{execution['individual_skipped_count']} skipped", flush=True)
    if enforce_floor:
        require(coverage["meets_threshold"], f"{scheme} source coverage is below the unchanged {coverage['threshold']}% floor")
    return coverage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    workspace = Path.cwd().resolve()
    invocation = {"sha": command("git", "rev-parse", "HEAD").strip(),
                  "run_id": os.environ.get("GITHUB_RUN_ID", "local"),
                  "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "local")}
    if os.environ.get("GITHUB_SHA"):
        require(invocation["sha"] == os.environ["GITHUB_SHA"], "Checkout differs from GITHUB_SHA")
    audit_evidence(args.evidence, workspace, invocation)


if __name__ == "__main__":
    try:
        main()
    except (CoverageError, OSError, ValueError, ET.ParseError, subprocess.SubprocessError) as error:
        print(f"::error::{error}", file=sys.stderr)
        sys.exit(1)
