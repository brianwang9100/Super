#!/usr/bin/env python3
"""Keep concrete iOS simulator commands on CI's exact snapshot toolchain.

Pins come from .github/workflows/ios-build.yml, including the independent
XCODE_BUILD literal: a setup-xcode beta selector does not identify a beta build.
Missing, malformed, conflicting, or unresolvable pins fail closed for concrete
simulator commands. Unrelated commands and generic simulator builds are ignored.

SUPER_IOS_COMPATIBILITY=1 permits build/build-for-testing on another iOS runtime
with the pinned Xcode. It never permits test execution or snapshot recording;
install/launch the resulting app with simctl for manual compatibility checks.
"""
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple


DOC = 'AGENTS.md "iOS testing: match CI\'s Xcode + simulator runtime + iPhone"'
WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/ios-build.yml"
DESTINATION = re.compile(r'''-destination\s+(?:"([^"]*)"|'([^']*)'|(\S+))''')
VERSION = r"[0-9]+\.[0-9]+(?:\.[0-9]+)?"
BUILD = r"[0-9]+[A-Z][0-9A-Za-z]+"


class PinError(ValueError):
    """An authoritative workflow pin cannot be read unambiguously."""


class Pin(NamedTuple):
    """The simulator identity and exact compiler/runtime builds used by CI."""

    device: str
    os_version: str
    runtime_build: str
    xcode_selector: str
    xcode_build: str

    @property
    def device_type(self):
        return "com.apple.CoreSimulator.SimDeviceType." + self.device.replace(" ", "-")


def unique_literal(values, name, pattern):
    """Require every occurrence to be a valid, identical literal."""
    if not values:
        raise PinError("missing " + name)
    parsed = []
    for value in values:
        value = value.strip()
        if value[:1] in ("'", '"'):
            if len(value) < 2 or value[-1] != value[0]:
                raise PinError("malformed " + name)
            value = value[1:-1]
        if not re.fullmatch(pattern, value):
            raise PinError("malformed " + name)
        parsed.append(value)
    if len(set(parsed)) != 1:
        raise PinError("conflicting " + name + " values")
    return parsed[0]


def parse_pin(text):
    """Parse the workflow's documented literal shapes without stale fallbacks."""
    # Ignore standalone YAML/shell comments, including their example literals.
    text = "\n".join(line for line in text.splitlines()
                     if not line.lstrip().startswith("#"))
    xcode = unique_literal(
        re.findall(r"^\s*xcode-version:\s*([^\n#]*)(?:#.*)?$", text, re.M),
        "xcode-version", VERSION + r"(?:-beta)?")
    xcode_build = unique_literal(
        re.findall(r"^\s*XCODE_BUILD:\s*([^\n#]*)(?:#.*)?$", text, re.M),
        "XCODE_BUILD", BUILD)
    runtime_build = unique_literal(
        re.findall(r"^\s*RUNTIME_BUILD=([^\n#]*)(?:#.*)?$", text, re.M),
        "RUNTIME_BUILD", BUILD)
    os_version = unique_literal(
        re.findall(r'''simctl\s+list\s+devices\s+--json\s+["']iOS\s+([^"']+)["']''', text),
        "simulator OS", r"[0-9]+\.[0-9]+")
    device = unique_literal(
        re.findall(r'''\.get\(["']name["']\)\s*==\s*["']([^"']+)["']''', text),
        "simulator device", r"iPhone [0-9A-Za-z ()+-]+")
    runtime_ids = set(re.findall(r"SimRuntime\.iOS-([0-9]+-[0-9]+)", text))
    if runtime_ids and runtime_ids != {os_version.replace(".", "-")}:
        raise PinError("conflicting simulator runtime identifier and OS")
    return Pin(device, os_version, runtime_build, xcode, xcode_build)


def load_pin(workflow=WORKFLOW):
    """Read the checked-in workflow; failure must not resurrect an old pin."""
    try:
        return parse_pin(workflow.read_text(encoding="utf-8"))
    except OSError as error:
        raise PinError("cannot read " + str(workflow)) from error


def parse_kv(destination):
    """Split a destination into key/value pairs, rejecting conflicting keys."""
    values = {}
    for part in destination.split(","):
        if "=" not in part:
            continue
        key, value = (item.strip() for item in part.split("=", 1))
        if key in values and values[key] != value:
            raise ValueError("conflicting -destination " + key)
        values[key] = value
    return values


def command_environment(command, environment):
    """Honor literal inline overrides for both xcodebuild and xcrun probes."""
    result = dict(environment)
    names = ("DEVELOPER_DIR", "SUPER_IOS_COMPATIBILITY", "SNAPSHOT_RECORD",
             "TEST_RUNNER_SNAPSHOT_RECORD")
    for name in names:
        matches = re.findall(
            r"(?:^|\s)" + name + r'''=(?:"([^"]*)"|'([^']*)'|([^\s;|&]+))''', command)
        values = {a or b or c for a, b, c in matches}
        if len(values) > 1:
            raise ValueError("multiple " + name + " overrides cannot be verified")
        if values:
            value = values.pop()
            if "$" in value or "`" in value:
                raise ValueError("use a literal " + name + " override")
            result[name] = value
    return result


def output(arguments, environment):
    """Run a bounded, read-only toolchain inventory command."""
    return subprocess.run(arguments, capture_output=True, text=True, timeout=10,
                          env=environment, check=True).stdout


def normalized_version(version):
    components = [int(part) for part in version.split(".")]
    while len(components) > 1 and components[-1] == 0:
        components.pop()
    return tuple(components)


def check_xcode(pin, environment, run):
    """Check a beta's build independently from its marketing version."""
    raw = run(["xcodebuild", "-version"], environment)
    version = re.search(r"^Xcode\s+(" + VERSION + r")\s*$", raw, re.M)
    build = re.search(r"^Build version\s+(" + BUILD + r")\s*$", raw, re.M)
    if not version or not build:
        return "Cannot verify the selected Xcode version and build. Run xcodebuild -version."
    expected_version = pin.xcode_selector.removesuffix("-beta")
    if (normalized_version(version.group(1)) != normalized_version(expected_version)
            or build.group(1) != pin.xcode_build):
        return ("Selected Xcode is " + version.group(1) + " (" + build.group(1)
                + "), but CI requires " + pin.xcode_selector + " (" + pin.xcode_build
                + "). Select that exact Xcode using a literal DEVELOPER_DIR override "
                "or xcode-select before recording or verifying snapshots. See " + DOC + ".")
    return None


def check_runtime(pin, environment, run):
    """Verify both available runtimes and installed disk images for ambiguity."""
    data = json.loads(run(["xcrun", "simctl", "list", "runtimes", "--json"], environment))
    builds = []
    for runtime in data["runtimes"]:
        if not runtime.get("isAvailable"):
            continue
        if not runtime.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS-"):
            continue
        version = runtime.get("version", "")
        if version == pin.os_version or version.startswith(pin.os_version + "."):
            builds.append(runtime.get("buildversion"))
    if builds != [pin.runtime_build]:
        found = ", ".join(str(build or "unknown") for build in builds) or "none"
        return ("CI requires exactly one available iOS " + pin.os_version
                + " runtime at build " + pin.runtime_build + "; found: " + found
                + ". Same-minor simulator installs cannot reliably select a build by "
                "destination. Inspect xcrun simctl runtime list and coordinate any "
                "runtime changes with other worktrees before retrying. See " + DOC + ".")
    # `list runtimes` can collapse two installed point builds to one runtime
    # identifier. Inspect disk images separately so the hidden image cannot
    # change which renderer a same-minor destination uses.
    images = json.loads(run(["xcrun", "simctl", "runtime", "list", "-j"], environment))
    image_builds = []
    runtime_id = "com.apple.CoreSimulator.SimRuntime.iOS-" + pin.os_version.replace(".", "-")
    for image in images.values():
        identifier = image.get("runtimeIdentifier", "")
        if not identifier.startswith("com.apple.CoreSimulator.SimRuntime.iOS-"):
            continue
        version = image.get("version", "")
        if (identifier == runtime_id or version == pin.os_version
                or version.startswith(pin.os_version + ".")):
            image_builds.append(image.get("build"))
    if image_builds != [pin.runtime_build]:
        found = ", ".join(str(build or "unknown") for build in image_builds) or "none"
        return ("CI requires exactly one installed iOS " + pin.os_version
                + " disk image at build " + pin.runtime_build + "; found: " + found
                + ". simctl list runtimes may hide same-minor images. Inspect xcrun "
                "simctl runtime list and coordinate runtime changes with other worktrees.")
    return None


def matching_devices(values, environment, run):
    """Resolve literal UDIDs/custom names without treating names as device types."""
    data = json.loads(run(["xcrun", "simctl", "list", "devices", "--json"], environment))
    found = []
    for runtime, devices in data["devices"].items():
        match = re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+)-(\d+)", runtime)
        if not match:
            continue
        os_version = match.group(1) + "." + match.group(2)
        for device in devices:
            if device.get("isAvailable") is False:
                continue
            if values.get("id"):
                matches = device.get("udid") == values["id"]
            else:
                matches = (device.get("name") == values.get("name")
                           and os_version == values.get("OS"))
            if matches:
                found.append((device, os_version))
    return found


def check_destination(destination, pin, environment, run):
    """Verify each destination, including a dedicated worktree simulator."""
    values = parse_kv(destination)
    if not values.get("id") and not values.get("name"):
        return "Pin an explicit simulator name and OS, or a literal UDID: " + destination
    if not values.get("id") and not values.get("OS"):
        return "Add OS=" + pin.os_version + " to the simulator destination: " + destination
    if any("$" in value or "`" in value for value in values.values()):
        return "Use a literal simulator UDID or name/OS so snapshot pins can be verified."
    if values.get("OS") and values["OS"] != pin.os_version:
        return "CI snapshot runtime is iOS " + pin.os_version + ", not " + values["OS"] + "."
    # Names are mutable, even the canonical one. Every destination must resolve
    # to exactly one simulator with the pinned immutable hardware identifier.
    matches = matching_devices(values, environment, run)
    if len(matches) != 1:
        return "Cannot resolve exactly one available simulator for: " + destination
    device, os_version = matches[0]
    device_type = device.get("deviceTypeIdentifier")
    hardware_matches = device_type == pin.device_type
    if not hardware_matches or os_version != pin.os_version:
        return ("This destination is not CI's " + pin.device + " / iOS "
                + pin.os_version + ": " + destination + ". See " + DOC + ".")
    return None


def compatibility_reason(command, environment):
    """Compatibility mode compiles apps but cannot execute screenshot suites."""
    if any(environment.get(name) == "1" for name in
           ("SNAPSHOT_RECORD", "TEST_RUNNER_SNAPSHOT_RECORD")):
        return "SUPER_IOS_COMPATIBILITY refuses snapshot recording. Unset the recording flags."
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
    if any(token in {"test", "test-without-building"} for token in tokens):
        return ("SUPER_IOS_COMPATIBILITY allows build/build-for-testing only, never test "
                "execution against another runtime's snapshot baselines. Install and "
                "launch the built app with simctl for manual iOS compatibility checks.")
    if not any(token in {"build", "build-for-testing"} for token in tokens):
        return "SUPER_IOS_COMPATIBILITY requires an explicit build or build-for-testing action."
    return None


def evaluate(command, workflow=WORKFLOW, environment=None, run=output):
    """Return a denial reason, or None to preserve the PreToolUse allow contract."""
    if "xcodebuild" not in command:
        return None
    destinations = [a or b or c for a, b, c in DESTINATION.findall(command)]
    concrete = [destination for destination in destinations
                if "platform=iOS Simulator" in destination and "generic/" not in destination]
    if not concrete:
        return None
    try:
        pin = load_pin(workflow)
        selected_environment = command_environment(
            command, os.environ if environment is None else environment)
        reason = check_xcode(pin, selected_environment, run)
        if reason:
            return reason
        if selected_environment.get("SUPER_IOS_COMPATIBILITY") == "1":
            return compatibility_reason(command, selected_environment)
        reason = check_runtime(pin, selected_environment, run)
        if reason:
            return reason
        for destination in concrete:
            reason = check_destination(destination, pin, selected_environment, run)
            if reason:
                return reason
    except PinError as error:
        return ("Cannot verify CI snapshot pins: " + str(error)
                + ". Fix .github/workflows/ios-build.yml; the guard has no fallback pins.")
    except (OSError, ValueError, KeyError, TypeError, AttributeError,
            subprocess.SubprocessError) as error:
        return ("Cannot verify the concrete iOS simulator command (" + type(error).__name__
                + "). Verify the selected Xcode and simctl inventory before retrying.")
    return None


def main():
    """Read the existing Bash hook payload and emit only actionable denials."""
    try:
        payload = json.load(sys.stdin)
        command = (payload.get("tool_input") or {}).get("command") or ""
    except (ValueError, AttributeError, TypeError):
        return
    if not isinstance(command, str):
        return
    reason = evaluate(command)
    if reason:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }}))


if __name__ == "__main__":
    main()
