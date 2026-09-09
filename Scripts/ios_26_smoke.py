#!/usr/bin/env python3
"""Compile with Xcode 27 and prove bounded process startup on exact iOS 26.0."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import threading
import time


XCODE_BUILD = "27A5252f"
RUNTIME_BUILD = "23A343"
RUNTIME_IDENTIFIER = "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
BUNDLE_IDS = {"Super": "com.brianwang.Super", "SuperBible": "com.brianwang.SuperBible"}
BOOT_TIMEOUT_SECONDS = 10 * 60
INSTALL_TIMEOUT_SECONDS = 10 * 60
LAUNCH_TIMEOUT_SECONDS = 120
DIAGNOSTIC_TIMEOUT_SECONDS = 15


class SmokeError(RuntimeError):
    """A prerequisite, build, or startup condition failed without substitution."""


def require(condition, message):
    if not condition:
        raise SmokeError(message)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def select_runtime(inventory):
    matches = [runtime for runtime in inventory["runtimes"] if runtime.get("identifier") == RUNTIME_IDENTIFIER]
    require(len(matches) == 1 and matches[0].get("isAvailable")
            and matches[0].get("version") in ("26.0", "26.0.0")
            and matches[0].get("buildversion") == RUNTIME_BUILD,
            f"Expected exactly one available iOS 26.0 runtime at {RUNTIME_BUILD}; got {matches}")
    return matches[0]


def select_export(export_directory):
    bundles = [path for path in export_directory.rglob("*.exportedBundle") if path.is_dir()]
    require(len(bundles) == 1, f"Expected exactly one exportedBundle, found {len(bundles)}")
    bundle = bundles[0]
    require(not bundle.is_symlink() and bundle.resolve().is_relative_to(export_directory.resolve()),
            "Export bundle must remain inside this job's dedicated export directory")
    return bundle


def validate_binary(info, load_commands, scheme):
    require(info.get("CFBundleIdentifier") == BUNDLE_IDS[scheme], "Unexpected app bundle identifier")
    require(info.get("CFBundleExecutable") == scheme, "Unexpected app executable")
    require(info.get("MinimumOSVersion") in ("26.0", "26.0.0"), "App no longer deploys to iOS 26.0")
    require(re.search(r"^\s*platform IOSSIMULATOR\s*$", load_commands, re.MULTILINE), "Not a simulator binary")
    require(re.search(r"^\s*minos 26(?:\.0){1,2}\s*$", load_commands, re.MULTILINE), "Mach-O minimum OS is not 26.0")
    require(re.search(r"^\s*sdk 27(?:\.0){1,2}\s*$", load_commands, re.MULTILINE), "Binary was not built with the iOS 27 SDK")


def launch_pid(output, bundle_id):
    matches = re.findall(r"^" + re.escape(bundle_id) + r":\s*([0-9]+)\s*$", output, re.MULTILINE)
    require(len(matches) == 1 and int(matches[0]) > 1, "simctl did not return one valid app PID")
    return int(matches[0])


def validate_process(output, executable, expected_path=None):
    parts = output.strip().split(maxsplit=1)
    require(len(parts) == 2 and not parts[0].startswith("Z")
            and Path(parts[1]).name == executable, "App exited, became a zombie, or PID changed identity")
    if expected_path is not None:
        require(Path(parts[1]) == expected_path, "Process does not belong to this simulator's installed app")


def installed_executable(output, simulator, scheme):
    """Scope diagnostic process discovery to this job's exact app container."""
    path = Path(output.strip())
    require(path.is_absolute() and ".." not in path.parts and "\n" not in output.strip()
            and path.name == f"{scheme}.app"
            and path.parts[-9:-2] == ("CoreSimulator", "Devices", simulator,
                                      "data", "Containers", "Bundle", "Application")
            and re.fullmatch(r"[0-9A-Fa-f-]{36}", path.parts[-2]),
            "Installed app path is not inside this job's dedicated simulator")
    return path / scheme


def diagnostic_pid(output):
    """Never choose one process from an ambiguous diagnostic lookup."""
    identifiers = output.split()
    require(len(identifiers) == 1 and identifiers[0].isdigit() and int(identifiers[0]) > 1,
            "Diagnostic lookup did not identify exactly one app process")
    return int(identifiers[0])


def literal_process_pattern(path):
    # pgrep uses POSIX extended expressions, not Python's regex dialect.
    # Escape only ERE metacharacters; ordinary characters such as '-' stay literal.
    return re.sub(r"([.\^$*+?{}\[\]\\|()])", r"\\\1", str(path))


def build_command(root, scheme, configuration, simulator):
    require(scheme in BUNDLE_IDS and configuration in ("Debug", "Release"), "Unknown build target/configuration")
    return ["xcodebuild", "build", "-project", "Super.xcodeproj", "-scheme", scheme,
            "-configuration", configuration, "-sdk", "iphonesimulator",
            "-destination", f"platform=iOS Simulator,id={simulator}",
            "-derivedDataPath", str(root / "derived"), "-skipPackagePluginValidation",
            "-resultBundlePath", str(root / "evidence" / f"{scheme}-{configuration}.xcresult"),
            "CODE_SIGNING_ALLOWED=NO"]


def boot_simulator(runner, configuration):
    """Boot only a new dedicated device, allowing bounded first-boot migration."""
    require(configuration in ("Debug", "Release"), "Unknown simulator configuration")
    simulator = runner.run(f"create-{configuration}", ["xcrun", "simctl", "create",
                           f"IOS26Smoke-{configuration}", "iPhone 17", RUNTIME_IDENTIFIER]).strip()
    require(re.fullmatch(r"[0-9A-Fa-f-]{36}", simulator), "Unexpected simulator identifier")
    runner.created_simulators.add(simulator)
    runner.run(f"boot-{configuration}", ["xcrun", "simctl", "boot", simulator])
    # The first hosted iOS 26 boot finished after 5m26s. Give each fresh device
    # ten minutes; SmokeRunner still enforces the unchanged global deadline.
    runner.run(f"boot-ready-{configuration}", ["xcrun", "simctl", "bootstatus", simulator, "-b"],
               timeout=BOOT_TIMEOUT_SECONDS)
    return simulator


def install_diagnostics(runner, simulator, app, scheme, configuration):
    """Collect only resource metrics and this job's app-installation evidence."""
    require(simulator in runner.created_simulators, "Diagnostics require a simulator created by this job")
    require(scheme in BUNDLE_IDS and configuration in ("Debug", "Release"), "Unknown diagnostic target")
    name = f"{scheme}-{configuration}"
    bundle_id = BUNDLE_IDS[scheme]
    # No host process logs, simulator-wide log dumps, or unrelated app data.
    # Six probes each have a 15-second cap and share the original global limit.
    probes = (
        ("disk", ["df", "-k", str(runner.evidence)]),
        ("memory", ["vm_stat"]),
        ("load", ["sysctl", "vm.loadavg"]),
        ("app-size", ["du", "-sk", str(app)]),
        ("app-container", ["xcrun", "simctl", "get_app_container", simulator, bundle_id, "app"]),
        ("installer", ["xcrun", "simctl", "spawn", simulator, "log", "show", "--last", "5m",
                       "--style", "compact", "--predicate",
                       f'process == "installd" AND eventMessage CONTAINS "{bundle_id}"']),
    )
    results = []
    for probe, arguments in probes:
        stage = f"diagnostic-{name}-{probe}"
        try:
            runner.run(stage, arguments, timeout=DIAGNOSTIC_TIMEOUT_SECONDS)
            results.append({"stage": stage, "result": "collected"})
        except (SmokeError, subprocess.SubprocessError, OSError) as error:
            results.append({"stage": stage, "result": "unavailable", "error": str(error)})
    write_json(runner.evidence / f"install-{name}-diagnostics.json", {
        "simulator": simulator, "bundle_id": bundle_id, "probes": results,
        "scope": "Resource metrics and app-specific installation evidence only; not startup proof.",
    })


def install_app(runner, simulator, app, scheme, configuration):
    """Bound one installation attempt; diagnostics never turn failure into success."""
    require(simulator in runner.created_simulators, "Installation requires a simulator created by this job")
    require(scheme in BUNDLE_IDS and configuration in ("Debug", "Release"), "Unknown installation target")
    stage = f"install-{scheme}-{configuration}"
    try:
        runner.run(stage, ["xcrun", "simctl", "install", simulator, str(app)], timeout=INSTALL_TIMEOUT_SECONDS)
    except (SmokeError, subprocess.SubprocessError, OSError):
        try:
            install_diagnostics(runner, simulator, app, scheme, configuration)
        except Exception as error:
            # Evidence collection (including a disk-write failure) must not
            # replace the original install failure in main's failure.json.
            print(f"Installation diagnostics unavailable: {error}", flush=True)
        finally:
            runner.stage = stage
        raise


def launch_diagnostics(runner, simulator, scheme, configuration):
    """Collect bounded app-only evidence without converting failure to success."""
    require(simulator in runner.created_simulators, "Diagnostics require a simulator created by this job")
    require(scheme in BUNDLE_IDS and configuration in ("Debug", "Release"), "Unknown diagnostic target")
    name = f"{scheme}-{configuration}"
    bundle_id = BUNDLE_IDS[scheme]
    results = []

    def collect(probe, arguments, validate=None):
        stage = f"diagnostic-launch-{name}-{probe}"
        try:
            output = runner.run(stage, arguments, timeout=DIAGNOSTIC_TIMEOUT_SECONDS)
            if validate is not None:
                validate(output)
            results.append({"stage": stage, "result": "collected"})
            return output
        except (SmokeError, subprocess.SubprocessError, OSError) as error:
            results.append({"stage": stage, "result": "unavailable", "error": str(error)})
            return None

    # Capture only the fresh, owned device; never read a shared screen, process
    # inventory, conversation database, or unfiltered host/simulator log store.
    # Prefer the short-lived process evidence before potentially slow services.
    container = collect("app-container", ["xcrun", "simctl", "get_app_container", simulator, bundle_id, "app"],
                        lambda output: installed_executable(output, simulator, scheme))
    pid = None
    if container is not None:
        executable = installed_executable(container, simulator, scheme)
        matches = collect("app-pid", ["pgrep", "-f", "-x", literal_process_pattern(executable)], diagnostic_pid)
        if matches is not None:
            candidate = diagnostic_pid(matches)
            identity = collect("app-identity", ["ps", "-p", str(candidate), "-o", "state=", "-o", "comm="],
                               lambda output: validate_process(output, scheme, expected_path=executable))
            if identity is not None:
                pid = candidate
                # sample captures stack symbols, not app memory or conversation
                # data. Explicit PID, duration, interval, file, and outer cap.
                collect("app-stack", ["sample", str(pid), "3", "10", "-file",
                                      str(runner.evidence / f"diagnostic-{name}-sample.txt")])
    collect("screenshot", ["xcrun", "simctl", "io", simulator, "screenshot",
                           str(runner.evidence / f"diagnostic-{name}.png")])
    collect("disk", ["df", "-k", str(runner.evidence)])
    collect("memory", ["vm_stat"])
    collect("load", ["sysctl", "vm.loadavg"])
    collect("launch-services", ["xcrun", "simctl", "spawn", simulator, "log", "show", "--last", "5m",
                                "--style", "compact", "--predicate",
                                '(process == "SpringBoard" OR process == "runningboardd" OR process == "launchd") '
                                f'AND eventMessage CONTAINS "{bundle_id}"'])
    write_json(runner.evidence / f"launch-{name}-diagnostics.json", {
        "simulator": simulator, "bundle_id": bundle_id, "validated_app_pid": pid, "probes": results,
        "scope": "Failure-only screenshot, app stack, system launch lifecycle, and resource metrics; not startup proof.",
    })


def launch_app(runner, simulator, scheme, configuration):
    """Require one acknowledged launch; diagnostics never authorize a retry."""
    require(simulator in runner.created_simulators, "Launch requires a simulator created by this job")
    require(scheme in BUNDLE_IDS and configuration in ("Debug", "Release"), "Unknown launch target")
    name = f"{scheme}-{configuration}"
    stage = f"launch-{name}"
    try:
        output = runner.run(stage, ["xcrun", "simctl", "launch",
                            f"--stdout={runner.evidence / (name + '-stdout.log')}",
                            f"--stderr={runner.evidence / (name + '-stderr.log')}", simulator, BUNDLE_IDS[scheme]],
                            timeout=LAUNCH_TIMEOUT_SECONDS)
        return launch_pid(output, BUNDLE_IDS[scheme])
    except (SmokeError, subprocess.SubprocessError, OSError):
        try:
            launch_diagnostics(runner, simulator, scheme, configuration)
        except Exception as error:
            print(f"Launch diagnostics unavailable: {error}", flush=True)
        finally:
            runner.stage = stage
        raise


def record_completed_launches(runner, runtime, results):
    """Preserve completed startup cases without claiming the whole smoke passed."""
    write_json(runner.evidence / "completed-launches.json", {
        "commit": os.environ.get("GITHUB_SHA"), "xcode_build": XCODE_BUILD,
        "runtime": runtime, "launches": results, "status": "partial",
        "scope": "Completed startup cases only; success.json is required for the full smoke and unchanged snapshots.",
    })


def observe_process(runner, name, pid, executable, wait=time.sleep):
    """Observe bounded liveness; elapsed time, not a fixed sample count, matters."""
    first_completed = None
    samples = 0
    while True:
        probe_started = runner.clock()
        output = runner.run(f"process-{name}-{samples}", ["ps", "-p", str(pid), "-o", "state=", "-o", "comm="], timeout=10)
        validate_process(output, executable)
        probe_completed = runner.clock()
        samples += 1
        if first_completed is None:
            first_completed = probe_completed
        elif probe_started - first_completed >= 5:
            # The final valid sample must begin after the full window. Time
            # spent waiting for an earlier ps response cannot fake an endpoint.
            return {"process_samples": samples, "observation_seconds": probe_started - first_completed}
        remaining = first_completed + 5 - probe_completed
        if remaining > 0:
            wait(min(1, remaining))


class SmokeRunner:
    """Own the execution deadline, clean environment, and per-command evidence."""

    def __init__(self, evidence, clock=time.monotonic):
        self.evidence = evidence
        self.clock = clock
        self.deadline = clock() + 65 * 60
        self.stage = "initializing"
        self.created_simulators = set()
        self.environment = os.environ.copy()
        self.environment["SUPER_IOS_COMPATIBILITY"] = "1"
        for prefix in ("", "TEST_RUNNER_", "SIMCTL_CHILD_"):
            self.environment[prefix + "SNAPSHOT_RECORD"] = "0"
            self.environment[prefix + "SNAPSHOT_TESTING_RECORD"] = "never"

    def run(self, stage, arguments, timeout=120):
        self.stage = stage
        remaining = min(timeout, self.deadline - self.clock())
        require(remaining > 0, "Overall 65-minute smoke deadline reached")
        print(f"Starting {stage} (deadline {remaining:.0f}s)", flush=True)
        write_json(self.evidence / f"{stage}-command.json", {"arguments": arguments, "timeout_seconds": remaining})
        timed_out = threading.Event()
        output = []
        with (self.evidence / f"{stage}.log").open("w") as log:
            process = subprocess.Popen(arguments, env=self.environment, text=True, start_new_session=True,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

            def expire():
                timed_out.set()
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

            timer = threading.Timer(remaining, expire)
            timer.start()
            try:
                for line in process.stdout:
                    print(line, end="", flush=True)
                    log.write(line)
                    output.append(line)
                status = process.wait(timeout=30)
            finally:
                timer.cancel()
        require(not timed_out.is_set(), f"{stage} exceeded its deadline")
        require(status == 0, f"{stage} failed with exit code {status}")
        return "".join(output)


def snapshot_hashes(workspace):
    return {str(path.relative_to(workspace)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in (workspace / "Packages").glob("*/Tests/**/__Snapshots__/**/*") if path.is_file()}


def smoke(workspace, runner):
    output = workspace / "build" / "ios-26-smoke"
    version = runner.run("toolchain", ["xcodebuild", "-version"])
    require(re.search(r"^Build version " + XCODE_BUILD + "$", version, re.MULTILINE), "Unexpected Xcode build")
    require(shutil.disk_usage(output).free >= 25 * 1024**3,
            "At least 25 GiB free is required for runtime export/import and app builds; no caches will be deleted")
    export_directory = output / "runtime-export"
    export_directory.mkdir()
    runner.run("download-runtime", ["xcodebuild", "-downloadPlatform", "iOS", "-buildVersion", "26.0",
                                    "-architectureVariant", "arm64", "-exportPath", str(export_directory)], timeout=15 * 60)
    bundle = select_export(export_directory)
    runner.run("import-runtime", ["xcodebuild", "-importPlatform", str(bundle)], timeout=5 * 60)
    runtimes = json.loads(runner.run("runtime-inventory", ["xcrun", "simctl", "list", "runtimes", "--json"]))
    runtime = select_runtime(runtimes)
    write_json(runner.evidence / "runtime.json", runtime)

    results = []
    for configuration in ("Debug", "Release"):
        # Dedicated new devices preserve empty app containers for each config;
        # only devices created by this job are shut down, never shared devices.
        simulator = boot_simulator(runner, configuration)
        for scheme, bundle_id in BUNDLE_IDS.items():
            name = f"{scheme}-{configuration}"
            runner.run(f"build-{name}", build_command(output, scheme, configuration, simulator), timeout=20 * 60)
            app = output / "derived" / "Build" / "Products" / f"{configuration}-iphonesimulator" / f"{scheme}.app"
            info = plistlib.loads((app / "Info.plist").read_bytes())
            load_commands = runner.run(f"binary-{name}", ["xcrun", "vtool", "-show-build", str(app / scheme)])
            validate_binary(info, load_commands, scheme)
            install_app(runner, simulator, app, scheme, configuration)
            pid = launch_app(runner, simulator, scheme, configuration)
            # This is an explicitly bounded crash-observation window, not a
            # claim that the UI or async model registration has become ready.
            observation = observe_process(runner, name, pid, scheme)
            runner.run(f"screenshot-{name}", ["xcrun", "simctl", "io", simulator, "screenshot",
                                              str(runner.evidence / f"{name}.png")])
            runner.run(f"stop-{name}", ["xcrun", "simctl", "terminate", simulator, bundle_id])
            results.append({"scheme": scheme, "configuration": configuration, "simulator": simulator,
                            "bundle_id": bundle_id, "pid": pid, "minimum_os": info["MinimumOSVersion"],
                            **observation})
            record_completed_launches(runner, runtime, results)
        runner.run(f"shutdown-{configuration}", ["xcrun", "simctl", "shutdown", simulator])
    return {
        "commit": os.environ.get("GITHUB_SHA"), "xcode_build": XCODE_BUILD,
        "runtime": runtime, "launches": results,
        "scope": "Installation and five-second process liveness only; no UI assertions or model generation.",
        "remaining_validation": "Real-device UI, local generation, restored PCC on iOS 26, and entitled PCC remain unproven.",
    }


def main():
    workspace = Path.cwd().resolve()
    require(os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
            and Path(os.environ.get("GITHUB_WORKSPACE", "/")).resolve() == workspace,
            "This workflow only imports runtimes on a disposable GitHub-hosted checkout")
    evidence = workspace / "build" / "ios-26-smoke" / "evidence"
    require(not evidence.parent.exists(), "Refusing to overwrite an existing smoke run")
    evidence.mkdir(parents=True)
    runner = SmokeRunner(evidence)
    before = snapshot_hashes(workspace)
    write_json(evidence / "snapshot-inventory.json", before)
    try:
        result = smoke(workspace, runner)
        require(snapshot_hashes(workspace) == before, "Smoke run modified snapshot references")
        write_json(evidence / "success.json", result)
    except Exception as error:
        write_json(evidence / "failure.json", {"stage": runner.stage, "error": str(error)})
        raise


if __name__ == "__main__":
    try:
        main()
    except (SmokeError, subprocess.SubprocessError, OSError, ValueError) as error:
        print(f"::error::{error}", file=sys.stderr)
        sys.exit(1)
