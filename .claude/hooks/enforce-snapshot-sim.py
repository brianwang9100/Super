#!/usr/bin/env python3
"""Guard: any concrete iOS-Simulator `xcodebuild` run must match CI's pinned trio.

Snapshot baselines are pixel-exact comparisons, so a recording (or verification)
run on a different iPhone model, iOS runtime, or Xcode toolchain than CI uses
produces diffs that are pure environment drift, not real regressions — and a
"re-record to make it pass" on the wrong runtime is exactly how a baseline goes
bad. CI pins (see AGENTS.md "iOS testing: match CI's Xcode + simulator runtime
+ iPhone"): iPhone 17 / iOS 26.4 / Xcode 26.4.1.

The pin is NOT hardcoded here — it is read at runtime from the single source of
truth, .github/workflows/ios-build.yml (the `xcode-version:` input and the
"Pick iOS simulator" step). A repin therefore only edits that workflow; this
hook follows automatically. The FALLBACK_* constants below are used only when
the workflow cannot be read (renamed, or its format changed) so the guard
degrades to the last-known pin instead of silently going dead.

PreToolUse(Bash) hook. Reads the tool-call JSON on stdin and emits a deny via
the PreToolUse JSON contract when an `xcodebuild` command targets a concrete iOS
simulator that resolves to anything other than the pinned device/runtime, or
when the effective Xcode is not the pinned version. Fails OPEN (prints nothing,
allows the command) on anything it cannot positively confirm is wrong — a
variable-expanded destination, an unresolvable UDID, a missing toolchain — so it
never wedges an unrelated command.
"""
import json
import os
import re
import subprocess
import sys

# Last-known pin. Used ONLY when ios-build.yml cannot be read (see load_pin).
FALLBACK_DEVICE = "iPhone 17"
FALLBACK_OS = "26.4"
FALLBACK_XCODE = "26.4.1"

DOC = 'AGENTS.md "iOS testing: match CI\'s Xcode + simulator runtime + iPhone"'


def load_pin():
    """Read the pinned (device, os, xcode) from .github/workflows/ios-build.yml.

    Keys strictly off the authoritative tokens so a stray "iOS 26.2" in a
    comment can't be mistaken for the runtime: the device name and runtime come
    from the "Pick iOS simulator" step's selection logic, and the Xcode version
    from the setup-xcode action input (all `xcode-version:` values must agree).
    Any value that can't be read falls back to its FALLBACK_* constant.
    """
    device, osv, xcode = FALLBACK_DEVICE, FALLBACK_OS, FALLBACK_XCODE
    # <root>/.claude/hooks/<this>.py -> <root>/.github/workflows/ios-build.yml
    here = os.path.abspath(__file__)
    root = os.path.dirname(os.path.dirname(os.path.dirname(here)))
    workflow = os.path.join(root, ".github", "workflows", "ios-build.yml")
    try:
        with open(workflow, encoding="utf-8") as handle:
            text = handle.read()
    except Exception:
        return device, osv, xcode
    # The runtime CI actually selects: `simctl list devices --json "iOS 26.4"`.
    match = re.search(
        r'simctl\s+list\s+devices\s+--json\s+"iOS\s+([0-9]+\.[0-9]+)"', text)
    if match:
        osv = match.group(1)
    # The device the picker matches by name: `d.get("name")=="iPhone 17"`.
    match = re.search(r'\.get\("name"\)\s*==\s*"([^"]+)"', text)
    if match:
        device = match.group(1)
    # The setup-xcode input(s); enforce only if every occurrence agrees.
    versions = set(re.findall(r'xcode-version:\s*"?([0-9][0-9.]*)"?', text))
    if len(versions) == 1:
        xcode = versions.pop()
    return device, osv, xcode


def allow():
    sys.exit(0)


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)


try:
    payload = json.load(sys.stdin)
    cmd = (payload.get("tool_input") or {}).get("command") or ""
except Exception:
    allow()

# Fast path: only xcodebuild commands are ever in scope.
if "xcodebuild" not in cmd:
    allow()

# Every -destination argument (xcodebuild accepts more than one), unquoted.
_DEST = re.compile(r"""-destination\s+(?:"([^"]*)"|'([^']*)'|(\S+))""")
dests = [a or b or c for (a, b, c) in _DEST.findall(cmd)]

# Concrete iOS-simulator destinations only. A generic destination
# (generic/platform=iOS Simulator) is a build, not a device-bound test run, and
# pins no device/runtime — there is nothing to enforce against, so skip it.
concrete = [d for d in dests
            if "platform=iOS Simulator" in d and "generic/" not in d]
if not concrete:
    allow()

# Resolve the pin lazily — only now that we know this is a concrete iOS-sim run.
# This keeps the ios-build.yml read off the hot path for every non-xcodebuild
# command (and for generic builds), which is the overwhelming majority.
PIN_DEVICE, PIN_OS, PIN_XCODE = load_pin()


def parse_kv(dest):
    """Split a destination string into its key=value pairs."""
    out = {}
    for part in dest.split(","):
        if "=" in part:
            key, value = part.split("=", 1)
            out[key.strip()] = value.strip()
    return out


def resolve_udid(udid):
    """Resolve a literal simulator UDID to (device_name, os_version) via simctl.

    Returns (None, None) when simctl is unavailable or the UDID is not present —
    callers treat that as fail-open, not a mismatch.
    """
    try:
        raw = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "--json"],
            capture_output=True, text=True, timeout=10, check=True).stdout
        data = json.loads(raw)
    except Exception:
        return (None, None)
    for runtime_id, devices in (data.get("devices") or {}).items():
        for device in devices:
            if device.get("udid") == udid:
                # runtime_id like com.apple.CoreSimulator.SimRuntime.iOS-26-4
                match = re.search(r"iOS-(\d+)-(\d+)", runtime_id)
                osv = (match.group(1) + "." + match.group(2)) if match else None
                return (device.get("name"), osv)
    return (None, None)


def mismatch_reason(found_device, found_os, dest):
    return (
        "iOS snapshot runs must match CI's pinned simulator: "
        + PIN_DEVICE + " / iOS " + PIN_OS + ". This -destination resolves to "
        + (found_device or "an unknown device") + " / iOS "
        + (found_os or "unknown") + " (" + dest + "). Recording or verifying on "
        "the wrong device or runtime drifts the pixel-exact baselines. Use "
        '-destination "platform=iOS Simulator,name=' + PIN_DEVICE + ",OS="
        + PIN_OS + '". See ' + DOC + "."
    )


for dest in concrete:
    kv = parse_kv(dest)
    name, osv, sid = kv.get("name"), kv.get("OS"), kv.get("id")

    if sid is not None:
        if "$" in sid or "`" in sid:
            # Shell-expanded UDID (e.g. id=$SIM_UDID) — cannot statically
            # confirm what it points at. Fail open for this destination.
            continue
        rname, rosv = resolve_udid(sid)
        if rname is None:
            # simctl unavailable or UDID not on this machine. Fail open.
            continue
        if rname != PIN_DEVICE or rosv != PIN_OS:
            deny(mismatch_reason(rname, rosv, dest))
        continue

    if name is None:
        # platform=iOS Simulator with neither a name nor an id: xcodebuild picks
        # an arbitrary device, which is precisely how a run lands on the wrong
        # runtime. Require an explicit pin.
        deny(
            "This -destination names no device (" + dest + "), so xcodebuild "
            "picks one arbitrarily and the snapshot baselines drift. Pin it: "
            '-destination "platform=iOS Simulator,name=' + PIN_DEVICE + ",OS="
            + PIN_OS + '". See ' + DOC + "."
        )

    if osv is None:
        # name= without OS= silently selects the newest installed runtime — the
        # most common way a recording lands on a too-new iOS. This is the bug
        # the hook exists to stop.
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
    """Version of the Xcode this command will use: an inline DEVELOPER_DIR=
    override if present on the command line, else the xcode-select default.
    Returns the version string (e.g. '26.4.1') or None if it cannot be read.
    """
    env = dict(os.environ)
    match = re.search(r"""DEVELOPER_DIR=(?:"([^"]*)"|'([^']*)'|(\S+))""", cmd)
    if match:
        env["DEVELOPER_DIR"] = match.group(1) or match.group(2) or match.group(3)
    try:
        out = subprocess.run(
            ["xcodebuild", "-version"], capture_output=True, text=True,
            timeout=10, env=env, check=True).stdout
    except Exception:
        return None
    match = re.search(r"Xcode\s+([0-9][0-9.]*)", out)
    return match.group(1) if match else None


xcode = effective_xcode_version()
if xcode is not None and xcode != PIN_XCODE:
    deny(
        "Selected Xcode is " + xcode + ", but snapshot baselines are recorded "
        "and verified against Xcode " + PIN_XCODE + " — a toolchain mismatch "
        "shifts the system text renderer and SwiftUI layout, drifting the "
        "baselines. Select the pinned Xcode (xcode-select -s "
        "/Applications/Xcode-" + PIN_XCODE + ".app, or prefix the command with "
        "DEVELOPER_DIR=/Applications/Xcode-" + PIN_XCODE
        + ".app/Contents/Developer). See " + DOC + "."
    )

allow()
