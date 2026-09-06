#!/usr/bin/env python3
"""Guard concrete iOS Simulator xcodebuild runs against CI's pinned trio."""

import json
import os
import re
import subprocess
import sys

FALLBACK_DEVICE = "iPhone 17"
FALLBACK_OS = "26.4"
FALLBACK_BUILD = "23E254a"
FALLBACK_XCODE = "26.4.1"
DOC = 'docs/TESTING.md "Simulator environment"'


def load_pin():
    """Read the pinned device, runtime, build, and Xcode version from CI."""
    device, osv, build, xcode = (
        FALLBACK_DEVICE, FALLBACK_OS, FALLBACK_BUILD, FALLBACK_XCODE)
    here = os.path.abspath(__file__)
    root = os.path.dirname(os.path.dirname(os.path.dirname(here)))
    workflow = os.path.join(root, ".github", "workflows", "ios-build.yml")
    try:
        with open(workflow, encoding="utf-8") as handle:
            text = handle.read()
    except Exception:
        return device, osv, build, xcode
    match = re.search(
        r'simctl\s+list\s+devices\s+--json\s+"iOS\s+([0-9]+\.[0-9]+)"', text)
    if match:
        osv = match.group(1)
    match = re.search(r'RUNTIME_BUILD="?([0-9A-Za-z]+)"?', text)
    if match:
        build = match.group(1)
    match = re.search(r'\.get\("name"\)\s*==\s*"([^"]+)"', text)
    if match:
        device = match.group(1)
    versions = set(re.findall(r'xcode-version:\s*"?([0-9][0-9.]*)"?', text))
    if len(versions) == 1:
        xcode = versions.pop()
    return device, osv, build, xcode


def allow():
    """Exit successfully without producing a hook decision."""
    sys.exit(0)


def deny(reason):
    """Emit Codex's PreToolUse deny decision without failing the command hook."""
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)


try:
    payload = json.load(sys.stdin)
    tool_input = payload.get("tool_input") or {}
    cmd = tool_input.get("cmd") or tool_input.get("command") or ""
except Exception:
    allow()

if "xcodebuild" not in cmd:
    allow()

_DEST = re.compile(r'''-destination\s+(?:"([^"]*)"|'([^']*)'|(\S+))''')
dests = [a or b or c for (a, b, c) in _DEST.findall(cmd)]
concrete = [d for d in dests
            if "platform=iOS Simulator" in d and "generic/" not in d]
if not concrete:
    allow()

PIN_DEVICE, PIN_OS, PIN_BUILD, PIN_XCODE = load_pin()


def parse_kv(dest):
    """Split a destination string into key-value pairs."""
    out = {}
    for part in dest.split(","):
        if "=" in part:
            key, value = part.split("=", 1)
            out[key.strip()] = value.strip()
    return out


def resolve_udid(udid):
    """Resolve a literal simulator UDID, failing open when simctl is unavailable."""
    try:
        raw = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "--json"],
            capture_output=True, text=True, timeout=10, check=True).stdout
        data = json.loads(raw)
        raw_types = subprocess.run(
            ["xcrun", "simctl", "list", "devicetypes", "--json"],
            capture_output=True, text=True, timeout=10, check=True).stdout
        models = {item["identifier"]: item["name"]
                  for item in json.loads(raw_types)["devicetypes"]}
    except Exception:
        return None, None
    for runtime_id, devices in (data.get("devices") or {}).items():
        for device in devices:
            if device.get("udid") == udid:
                match = re.search(r"iOS-(\d+)-(\d+)", runtime_id)
                osv = (match.group(1) + "." + match.group(2)) if match else None
                # Worktree-owned devices have custom display names; the type is the model.
                return models.get(device.get("deviceTypeIdentifier")), osv
    return None, None


def mismatch_reason(found_device, found_os, dest):
    """Describe a concrete destination that diverges from CI's pinned trio."""
    return (
        "iOS snapshot runs must match CI's pinned simulator: "
        + PIN_DEVICE + " / iOS " + PIN_OS + ". This -destination resolves to "
        + (found_device or "an unknown device") + " / iOS "
        + (found_os or "unknown") + " (" + dest + "). Recording or verifying on "
        "the wrong device or runtime drifts the pixel-exact baselines. Use "
        '-destination "platform=iOS Simulator,name=' + PIN_DEVICE + ",OS="
        + PIN_OS + '". See ' + DOC + "."
    )


def installed_pinned_minor_builds():
    """Return available runtime builds on CI's pinned iOS minor, if readable."""
    try:
        raw = subprocess.run(
            ["xcrun", "simctl", "list", "runtimes", "--json"],
            capture_output=True, text=True, timeout=10, check=True).stdout
        data = json.loads(raw)
    except Exception:
        return None
    builds = []
    for runtime in data.get("runtimes") or []:
        if not runtime.get("isAvailable"):
            continue
        version = runtime.get("version") or ""
        if version == PIN_OS or version.startswith(PIN_OS + "."):
            builds.append(runtime.get("buildversion"))
    return builds


builds = installed_pinned_minor_builds()
if builds is not None:
    stale = sorted({build for build in builds if build and build != PIN_BUILD})
    if stale:
        deny(
            "iOS " + PIN_OS + " snapshot baselines are pinned to build "
            + PIN_BUILD + ", but this machine also has " + ", ".join(stale)
            + " installed. simctl conflates same-minor runtimes under one "
            "identifier (iOS-" + PIN_OS.replace(".", "-") + "), so a recording "
            "or verification on OS=" + PIN_OS + " can silently land on the wrong "
            "build and drift the pixel-exact baselines. Remove the stale runtime(s) "
            "so only " + PIN_BUILD + " remains: find the UUID with "
            "'xcrun simctl runtime list', then 'xcrun simctl runtime delete <uuid>'. "
            "See " + DOC + "."
        )


for dest in concrete:
    kv = parse_kv(dest)
    name, osv, sid = kv.get("name"), kv.get("OS"), kv.get("id")
    if sid is not None:
        if "$" in sid or "`" in sid:
            continue
        resolved_name, resolved_os = resolve_udid(sid)
        if resolved_name is None:
            continue
        if resolved_name != PIN_DEVICE or resolved_os != PIN_OS:
            deny(mismatch_reason(resolved_name, resolved_os, dest))
        continue
    if name is None:
        deny(
            "This -destination names no device (" + dest + "), so xcodebuild "
            "picks one arbitrarily and the snapshot baselines drift. Pin it: "
            '-destination "platform=iOS Simulator,name=' + PIN_DEVICE + ",OS="
            + PIN_OS + '". See ' + DOC + "."
        )
    if osv is None:
        deny(
            "This -destination pins name=" + name + " but no OS=, so xcodebuild "
            "selects the newest installed runtime — which drifts from CI's iOS "
            + PIN_OS + ". Add OS=" + PIN_OS + " explicitly: "
            '-destination "platform=iOS Simulator,name=' + PIN_DEVICE + ",OS="
            + PIN_OS + '". See ' + DOC + "."
        )
    if name != PIN_DEVICE or osv != PIN_OS:
        deny(mismatch_reason(name, osv, dest))


def effective_xcode_version():
    """Return the selected Xcode version, including a DEVELOPER_DIR override."""
    env = dict(os.environ)
    match = re.search(r'''DEVELOPER_DIR=(?:"([^"]*)"|'([^']*)'|(\S+))''', cmd)
    if match:
        env["DEVELOPER_DIR"] = match.group(1) or match.group(2) or match.group(3)
    try:
        output = subprocess.run(
            ["xcodebuild", "-version"], capture_output=True, text=True,
            timeout=10, env=env, check=True).stdout
    except Exception:
        return None
    match = re.search(r"Xcode\s+([0-9][0-9.]*)", output)
    return match.group(1) if match else None


xcode = effective_xcode_version()
if xcode is not None and xcode != PIN_XCODE:
    deny(
        "Selected Xcode is " + xcode + ", but snapshot baselines are recorded "
        "and verified against Xcode " + PIN_XCODE + " — a toolchain mismatch "
        "shifts the system text renderer and SwiftUI layout, drifting the baselines. "
        "Select the pinned Xcode (xcode-select -s /Applications/Xcode-"
        + PIN_XCODE + ".app, or prefix the command with DEVELOPER_DIR=/Applications/"
        "Xcode-" + PIN_XCODE + ".app/Contents/Developer). See " + DOC + "."
    )

allow()
