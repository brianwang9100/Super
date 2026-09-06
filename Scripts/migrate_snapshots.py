#!/usr/bin/env python3
"""Record a complete, verified PNG migration on an ephemeral hosted runner only."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


class MigrationError(RuntimeError):
    """A pin, inventory, or execution invariant prevented a safe migration."""


def require(condition, message):
    if not condition:
        raise MigrationError(message)


def command(*args):
    return subprocess.check_output(args, text=True)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def walk(value):
    """Visit JSON objects in both modern and legacy xcresult reports."""
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def discover_suites(directory):
    suites = []
    for source in sorted(directory.glob("*SnapshotTests.swift")):
        found = re.findall(r"@Suite\b[\s\S]*?^struct\s+(\w+)", source.read_text(), re.MULTILINE)
        require(found, f"No discoverable @Suite in {source}")
        suites.extend(found)
    require(suites and len(suites) == len(set(suites)), "Empty or duplicate snapshot suite inventory")
    return sorted(suites)


def fingerprints(root, paths):
    result = {}
    for path in paths:
        source = root / path
        require(source.is_file() and not source.is_symlink(), f"Missing or unsafe snapshot: {path}")
        content = source.read_bytes()
        if path.endswith(".png"):
            require(content.startswith(b"\x89PNG\r\n\x1a\n"), f"Invalid PNG: {path}")
        result[path] = hashlib.sha256(content).hexdigest()
    return result


def assert_png_inventory(root, directory, expected):
    actual = {str(path.relative_to(root)) for path in directory.rglob("*.png")}
    require(actual == set(expected),
            f"PNG inventory changed. Missing: {sorted(set(expected) - actual)}; "
            f"unexpected: {sorted(actual - set(expected))}")


def validate_report(summary, tree, legacy, exit_code, phase, suites):
    """Only comparison/recording assertions may fail before final verification."""
    total = summary.get("totalTestCount", 0)
    passed, failed = summary.get("passedTests", 0), summary.get("failedTests", 0)
    require(total > 0 and passed + failed == total, "Incomplete or empty test execution")
    require(summary.get("skippedTests") == 0 and summary.get("expectedFailures") == 0,
            "Skipped or expected-failure tests cannot establish migration coverage")
    require(exit_code == (65 if failed else 0), f"Unexpected xcodebuild exit code: {exit_code}")
    require(summary.get("result") == ("Failed" if failed else "Passed"), "Inconsistent test result")
    cases = [node for node in walk(tree) if node.get("nodeType") == "Test Case"]
    require(cases and all(node.get("result") in ("Passed", "Failed") for node in cases),
            "Missing, skipped, or incomplete test cases")
    identifiers = sorted(node.get("nodeIdentifier", "") for node in cases)
    require(all(identifiers) and len(identifiers) == len(set(identifiers)),
            "Missing or duplicate executed test identifiers")
    for suite in suites:
        require(any(re.search(r"\b" + re.escape(suite) + r"\b", identifier) for identifier in identifiers),
                f"Discovered suite did not execute: {suite}")

    # The legacy root contains complete issue lists, including build errors
    # that may not appear in the modern test-only summary. Do not tolerate a
    # compiler/runner failure merely because some snapshot tests also failed.
    messages = []
    for node in walk(legacy):
        require(not node.get("errorSummaries", {}).get("_values"), "Build or infrastructure error in xcresult")
        for issue in node.get("testFailureSummaries", {}).get("_values", []):
            messages.append(issue.get("message", {}).get("_value", ""))
    # Check modern summaries too; unknown beta report formats fail closed.
    for issue in summary.get("testFailures", []):
        messages.append(issue.get("failureText", ""))
    if phase == "verify":
        require(failed == 0 and not messages, "New references did not pass with recording disabled")
    else:
        require(not failed or len(messages) >= failed, "Failures missing from xcresult issue inventory")
        pattern = (r"Record mode is on\. Automatically recorded snapshot:"
                   if phase == "record" else r'Snapshot(?: "[^"]*")? does not match reference\.')
        require(all(re.search(pattern, message) for message in messages),
                "Non-snapshot failure (or unrecognized issue) requires investigation: "
                + "\n".join(message for message in messages if not re.search(pattern, message)))
        if phase == "record":
            require(failed > 0 and messages, "Recording seam was not exercised")
    return {"total": total, "test_identifiers": identifiers, "suites": suites}


def run_phase(root, evidence, derived, scheme, simulator, suites, phase):
    bundle = evidence / f"{phase}.xcresult"
    environment = os.environ.copy()
    # Set both the repository seam and library fallback explicitly. The prefix
    # is how xcodebuild forwards these values to the simulator's test process.
    for prefix in ("", "TEST_RUNNER_"):
        environment[prefix + "SNAPSHOT_RECORD"] = "1" if phase == "record" else "0"
        environment[prefix + "SNAPSHOT_TESTING_RECORD"] = "all" if phase == "record" else "never"
    arguments = ["xcodebuild", "test", "-project", "Super.xcodeproj", "-scheme", scheme,
                 "-destination", f"platform=iOS Simulator,id={simulator}",
                 "-skipPackagePluginValidation", "-derivedDataPath", str(derived),
                 "-resultBundlePath", str(bundle),
                 *[f"-only-testing:{scheme}Tests/{suite}" for suite in suites],
                 "CODE_SIGNING_ALLOWED=NO"]
    print(f"Starting {phase}: {len(suites)} suites", flush=True)
    with (evidence / f"{phase}.log").open("w") as log:
        process = subprocess.Popen(arguments, cwd=root, env=environment, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        for line in process.stdout:
            print(line, end="", flush=True)
            log.write(line)
        exit_code = process.wait()
    require(bundle.is_dir(), f"No xcresult for {phase}; xcodebuild exited {exit_code}")
    reports = {}
    for report in ("summary", "tests"):
        reports[report] = json.loads(command("xcrun", "xcresulttool", "get", "test-results", report,
                                             "--path", str(bundle)))
        write_json(evidence / f"{phase}-{report}.json", reports[report])
    reports["legacy"] = json.loads(command("xcrun", "xcresulttool", "get", "object", "--legacy",
                                           "--path", str(bundle), "--format", "json"))
    write_json(evidence / f"{phase}-issues.json", reports["legacy"])
    return validate_report(reports["summary"], reports["tests"], reports["legacy"], exit_code, phase, suites)


def migrate(args):
    root = Path.cwd().resolve()
    require(os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
            and Path(os.environ.get("GITHUB_WORKSPACE", "/")).resolve() == root,
            "Recording migration is restricted to an ephemeral GitHub-hosted checkout")
    output = root / "build" / "snapshot-migration" / args.scheme
    require(not output.exists(), f"Output already exists; refusing to overwrite: {output}")
    evidence = output / "evidence"
    evidence.mkdir(parents=True)
    version = command("xcodebuild", "-version")
    require(re.search(r"^Build version " + re.escape(args.xcode_build) + r"$", version, re.MULTILINE),
            f"Expected Xcode build {args.xcode_build}, got {version.strip()}")
    runtimes = json.loads(command("xcrun", "simctl", "list", "runtimes", "--json"))
    candidates = [runtime for runtime in runtimes["runtimes"]
                  if runtime.get("identifier") == "com.apple.CoreSimulator.SimRuntime.iOS-27-0"]
    require(len(candidates) == 1 and candidates[0].get("isAvailable")
            and candidates[0].get("buildversion") == args.runtime_build,
            f"Expected exactly one available iOS 27.0 runtime at {args.runtime_build}: {candidates}")
    write_json(evidence / "toolchain.json", {
        "xcode": version, "runtime": candidates[0], "device": "iPhone 17",
        "image": os.environ.get("ImageVersion"), "commit": os.environ.get("GITHUB_SHA"),
    })
    simulator = command("xcrun", "simctl", "create", f"SnapshotMigration-{args.scheme}", "iPhone 17",
                        candidates[0]["identifier"]).strip()
    command("xcrun", "simctl", "boot", simulator)
    command("xcrun", "simctl", "bootstatus", simulator, "-b")

    directory = root / "Packages" / args.scheme / "Tests" / f"{args.scheme}Tests" / "UI" / "Snapshots"
    suites = discover_suites(directory)
    tracked = command("git", "ls-files", "-z", "--", "Packages").split("\0")
    snapshots = [path for path in tracked if "/__Snapshots__/" in path]
    pngs = [path for path in snapshots if path.startswith(str(directory.relative_to(root)) + "/")
            and path.endswith(".png")]
    require(pngs, f"No tracked PNG baselines for {args.scheme}")
    originals = fingerprints(root, pngs)
    non_pngs = fingerprints(root, [path for path in snapshots if not path.endswith(".png")])
    assert_png_inventory(root, directory, pngs)
    write_json(evidence / "original-inventory.json", {"pngs": originals, "non_pngs": non_pngs, "suites": suites})
    for path in pngs:
        target = evidence / "originals" / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / path, target)

    previous = None
    for phase in ("original", "record", "verify"):
        if phase == "record":
            # The backup is recoverable. Removing only inventoried PNGs in this
            # disposable checkout proves that every baseline is re-created;
            # timestamps alone cannot distinguish stale, unexecuted fixtures.
            for path in pngs:
                (root / path).unlink()
        report = run_phase(root, evidence, root / "build" / "migration-derived", args.scheme,
                           simulator, suites, phase)
        assert_png_inventory(root, directory, pngs)
        require(fingerprints(root, non_pngs) == non_pngs, "Non-PNG snapshots changed")
        if previous is not None:
            require(report == previous, f"Executed test inventory changed during {phase}")
        previous = report
        write_json(evidence / f"{phase}-execution.json", report)
        current = fingerprints(root, pngs)
        if phase == "original":
            require(current == originals, "Verification modified the original references")
        elif phase == "record":
            recorded = current
        else:
            require(current == recorded, "Verification modified the newly recorded references")

    # Only a successful final verification creates the importable artifact.
    for path in pngs:
        target = output / "baselines" / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / path, target)
    write_json(evidence / "verified-inventory.json", {
        "pngs": recorded, "execution": previous,
        "changed": [path for path in pngs if originals[path] != recorded[path]],
    })
    print(f"Verified {len(pngs)} PNGs, {len(suites)} suites, {previous['total']} tests. "
          "Review differences before importing the artifact.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scheme", required=True, choices=("Core", "Chat", "Bible", "Todo"))
    parser.add_argument("--xcode-build", required=True)
    parser.add_argument("--runtime-build", required=True)
    try:
        migrate(parser.parse_args())
    except (MigrationError, subprocess.CalledProcessError) as error:
        print(f"::error::{error}", file=sys.stderr)
        sys.exit(1)
