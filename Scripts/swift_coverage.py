#!/usr/bin/env python3
"""Summarize a package's own source coverage from SwiftPM's exported report."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


class CoverageError(RuntimeError):
    """Successful tests did not produce unambiguous, measurable coverage."""


def require(condition, message):
    if not condition:
        raise CoverageError(message)


def report_path(output, package):
    """Use SwiftPM's reported path, never a guessed test-bundle layout."""
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    require(len(lines) == 1, "SwiftPM must report exactly one coverage JSON path")
    value = lines[0].removeprefix("Json: ")
    require(value.endswith(".json"), "Unexpected SwiftPM coverage-path output format")
    path = Path(value)
    path = (package / path).resolve() if not path.is_absolute() else path.resolve()
    require(path.is_relative_to((package / ".build").resolve()),
            "Coverage report is outside this package's build directory")
    require(path.is_file(), "SwiftPM's reported coverage JSON file does not exist")
    return path


def summarize(report, package):
    """Count only this package's Sources tree, excluding tests and dependencies."""
    require(isinstance(report, dict) and report.get("type") == "llvm.coverage.json.export",
            "Unexpected coverage report format")
    data = report.get("data")
    require(isinstance(data, list) and data, "Missing coverage data")
    package = package.resolve()
    sources = package / "Sources"
    files = {}
    for entry in data:
        require(isinstance(entry, dict) and isinstance(entry.get("files"), list),
                "Missing per-file coverage data")
        for item in entry["files"]:
            require(isinstance(item, dict) and isinstance(item.get("filename"), str),
                    "Missing coverage source filename")
            path = Path(item["filename"])
            path = (package / path).resolve() if not path.is_absolute() else path.resolve()
            if not path.is_relative_to(sources) or {"Tests", ".build"}.intersection(path.parts):
                continue
            relative = str(path.relative_to(package))
            require(relative not in files, "Duplicate package source in coverage report")
            summary = item.get("summary")
            require(isinstance(summary, dict) and isinstance(summary.get("lines"), dict),
                    "Missing source line coverage")
            lines = summary["lines"]
            count, covered = lines.get("count"), lines.get("covered")
            require(type(count) is int and type(covered) is int and 0 <= covered <= count,
                    "Invalid source line coverage counts")
            files[relative] = {"count": count, "covered": covered}
    count = sum(item["count"] for item in files.values())
    covered = sum(item["covered"] for item in files.values())
    require(files and count > 0, "No measurable package sources in coverage report")
    return {"count": count, "covered": covered, "files": dict(sorted(files.items()))}


def read_summary(path, package):
    try:
        report = json.loads(path.read_text())
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        # Do not echo arbitrary JSON or source payloads from a corrupt report.
        raise CoverageError("Cannot read the exported coverage JSON") from error
    return summarize(report, package)


def artifact_inventory(package, limit=40):
    """Return bounded artifact paths only; never profile, source, or JSON contents."""
    root = package / ".build"
    paths = set()
    for directory, children, filenames in os.walk(root):
        children[:] = sorted(child for child in children
                             if child not in ("checkouts", "repositories", "artifacts")
                             and not (Path(directory) / child).is_symlink())
        for name in children + filenames:
            path = Path(directory) / name
            if (path.suffix in (".profdata", ".profraw", ".xctest")
                    or "PackageTests" in name and path.suffix == ""
                    or path.suffix == ".json" and "codecov" in path.parts):
                paths.add(str(path.relative_to(package)))
    inventory = sorted(paths)
    return inventory[:limit], max(0, len(inventory) - limit)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    args = parser.parse_args()
    package = args.package.resolve()
    try:
        require((package / "Package.swift").is_file(), "Package.swift does not exist")
        command = subprocess.run(
            ["swift", "test", "--show-codecov-path"], cwd=package,
            text=True, capture_output=True, timeout=120, check=False,
        )
        require(command.returncode == 0, "SwiftPM coverage-path discovery failed")
        print("SwiftPM coverage-path output:")
        print(command.stdout.rstrip())
        summary = read_summary(report_path(command.stdout, package), package)
        print(f"\n{package.name} source line coverage: "
              f"{100 * summary['covered'] / summary['count']:.2f}% "
              f"({summary['covered']}/{summary['count']}; {len(summary['files'])} files)")
        print("Only this package's Sources/ files; excludes Tests/, .build/, and package dependencies.")
        print("Coverage reporting only; this step does not enforce a percentage threshold.")
        for filename, lines in summary["files"].items():
            percentage = f"{100 * lines['covered'] / lines['count']:.2f}%" if lines["count"] else "n/a"
            print(f"{percentage:>7} {lines['covered']:>6}/{lines['count']:<6} {filename}")
        return 0
    except (CoverageError, OSError, subprocess.TimeoutExpired) as error:
        message = str(error) if isinstance(error, CoverageError) else "Coverage discovery could not complete"
        print(f"::error::{message}", file=sys.stderr)
        print("Coverage artifact inventory (paths only):", file=sys.stderr)
        paths, omitted = artifact_inventory(package)
        for path in paths:
            print(path, file=sys.stderr)
        if not paths:
            print("(none found)", file=sys.stderr)
        if omitted:
            print(f"({omitted} additional paths omitted)", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
