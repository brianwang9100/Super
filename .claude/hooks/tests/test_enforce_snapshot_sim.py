"""Deterministic coverage of snapshot pin parsing and the Bash hook contract."""
import contextlib
import importlib.util
import io
import json
import re
import subprocess
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


HOOK_PATH = Path(__file__).resolve().parents[1] / "enforce-snapshot-sim.py"
SPEC = importlib.util.spec_from_file_location("enforce_snapshot_sim", HOOK_PATH)
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)

WORKFLOW = '''env:
  XCODE_BUILD: "27A5252f"
jobs:
  build:
    steps:
      - uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: "27.0-beta"
      - run: |
          RUNTIME_BUILD="24A5423a"
          xcrun simctl list runtimes --json
          # The actual picker contains this runtime identifier filter.
          runtime="com.apple.CoreSimulator.SimRuntime.iOS-27-0"
          xcrun simctl list devices --json "iOS 27.0"
          target=next(d for d in devices if d.get("name")=="iPhone 17")
'''
DESTINATION = '-destination "platform=iOS Simulator,name=iPhone 17,OS=27.0"'
COMMAND = "xcodebuild test -scheme CoreTests " + DESTINATION
RUNTIME_ID = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"


class Inventory:
    """Strict read-only subprocess double; unexpected probes fail the test."""

    def __init__(self):
        self.xcode = "Xcode 27.0\nBuild version 27A5252f\n"
        self.runtimes = [{
            "identifier": RUNTIME_ID,
            "version": "27.0",
            "buildversion": "24A5423a",
            "isAvailable": True,
        }]
        self.images = {"PINNED-IMAGE": {
            "runtimeIdentifier": RUNTIME_ID,
            "version": "27.0",
            "build": "24A5423a",
            "platformIdentifier": "com.apple.platform.iphonesimulator",
            "state": "Ready",
        }}
        self.device = {
            "udid": "WORKTREE-DEVICE",
            "name": "SB-6a40",
            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
            "isAvailable": True,
        }
        self.canonical_device = dict(self.device, name="iPhone 17", udid="CANONICAL-DEVICE")
        self.devices = {RUNTIME_ID: [self.device, self.canonical_device]}
        self.calls = []

    def __call__(self, arguments, environment):
        self.calls.append((arguments, dict(environment)))
        if arguments == ["xcodebuild", "-version"]:
            return self.xcode
        if arguments == ["xcrun", "simctl", "list", "runtimes", "--json"]:
            return json.dumps({"runtimes": self.runtimes})
        if arguments == ["xcrun", "simctl", "runtime", "list", "-j"]:
            return json.dumps(self.images)
        if arguments == ["xcrun", "simctl", "list", "devices", "--json"]:
            return json.dumps({"devices": self.devices})
        raise AssertionError("Unexpected inventory command: " + str(arguments))


class PinParsingTests(unittest.TestCase):
    """All authoritative literals must exist and agree, including beta builds."""

    def test_beta_selector_and_exact_build_are_independent(self):
        self.assertEqual(guard.parse_pin(WORKFLOW), guard.Pin(
            "iPhone 17", "27.0", "24A5423a", "27.0-beta", "27A5252f"))

    def test_stable_pin_remains_supported(self):
        source = (WORKFLOW.replace("27.0-beta", "26.4.1")
                  .replace("27A5252f", "17E202")
                  .replace("27.0", "26.4").replace("27-0", "26-4")
                  .replace("24A5423a", "23E254a"))
        self.assertEqual(guard.parse_pin(source), guard.Pin(
            "iPhone 17", "26.4", "23E254a", "26.4.1", "17E202"))

    def test_duplicate_consistent_literals_and_comments_are_supported(self):
        source = (WORKFLOW + '\n  xcode-version: "27.0-beta" # same pin\n'
                  '# xcode-version: "26.4.1"\n# RUNTIME_BUILD="23E254a"\n')
        self.assertEqual(guard.parse_pin(source).xcode_selector, "27.0-beta")

    def test_missing_literals_fail_closed(self):
        for line in ('  XCODE_BUILD: "27A5252f"',
                     '          xcode-version: "27.0-beta"',
                     '          RUNTIME_BUILD="24A5423a"',
                     '          xcrun simctl list devices --json "iOS 27.0"',
                     '          target=next(d for d in devices if d.get("name")=="iPhone 17")'):
            with self.subTest(line=line), self.assertRaises(guard.PinError):
                guard.parse_pin(WORKFLOW.replace(line, ""))

    def test_malformed_or_nonliteral_pins_fail_closed(self):
        for old, new in (("27.0-beta", "latest-beta"),
                         ("27.0-beta", "27.0-beta-garbage"),
                         ('"27A5252f"', '"27A5252f'),
                         ("27A5252f", "${{ vars.XCODE_BUILD }}"),
                         ("24A5423a", "$RUNTIME_BUILD")):
            with self.subTest(new=new), self.assertRaises(guard.PinError):
                guard.parse_pin(WORKFLOW.replace(old, new))

    def test_conflicting_literals_fail_closed(self):
        for extra in ('xcode-version: "27.0"', 'XCODE_BUILD: "27A5300a"',
                      'RUNTIME_BUILD="24A5430a"',
                      'xcrun simctl list devices --json "iOS 26.4"',
                      'd.get("name")=="iPhone 17 Pro"'):
            with self.subTest(extra=extra), self.assertRaises(guard.PinError):
                guard.parse_pin(WORKFLOW + "\n" + extra + "\n")

    def test_runtime_identifier_must_agree_with_device_query(self):
        with self.assertRaisesRegex(guard.PinError, "runtime identifier"):
            guard.parse_pin(WORKFLOW.replace("iOS-27-0", "iOS-26-4"))

    def test_checked_in_apple_workflows_share_exact_toolchain(self):
        root = HOOK_PATH.parents[2]
        primary = guard.load_pin(root / ".github/workflows/ios-build.yml")
        for name in ("ios-build.yml", "swift-test.yml", "testflight.yml"):
            with self.subTest(workflow=name):
                source = (root / ".github/workflows" / name).read_text(encoding="utf-8")
                source = "\n".join(line for line in source.splitlines()
                                   if not line.lstrip().startswith("#"))
                selectors = guard.unique_literal(re.findall(
                    r"^\s*xcode-version:\s*([^\n#]*)(?:#.*)?$", source, re.M),
                    "xcode-version", guard.VERSION + r"(?:-beta)?")
                builds = guard.unique_literal(re.findall(
                    r"^\s*XCODE_BUILD:\s*([^\n#]*)(?:#.*)?$", source, re.M),
                    "XCODE_BUILD", guard.BUILD)
                self.assertEqual(selectors, primary.xcode_selector)
                self.assertEqual(builds, primary.xcode_build)


class SnapshotGuardTests(unittest.TestCase):
    """Pin enforcement uses only injected inventory, never real simulators."""

    def setUp(self):
        self.workflow = Mock()
        self.workflow.read_text.return_value = WORKFLOW
        self.inventory = Inventory()

    def evaluate(self, command=COMMAND, environment=None):
        return guard.evaluate(command, workflow=self.workflow,
                              environment=environment or {}, run=self.inventory)

    def test_matching_pin_allows_verification_and_recording(self):
        self.assertIsNone(self.evaluate())
        self.assertIsNone(self.evaluate("TEST_RUNNER_SNAPSHOT_RECORD=1 " + COMMAND))

    def test_xcode_marketing_zero_component_is_normalized(self):
        self.inventory.xcode = "Xcode 27.0.0\nBuild version 27A5252f\n"
        self.assertIsNone(self.evaluate())

    def test_wrong_beta_build_is_denied_even_with_matching_version(self):
        self.inventory.xcode = "Xcode 27.0\nBuild version 27A5200a\n"
        self.assertIn("27A5252f", self.evaluate())

    def test_wrong_xcode_version_is_denied_even_with_matching_build(self):
        self.inventory.xcode = "Xcode 26.4.1\nBuild version 27A5252f\n"
        self.assertIn("27.0-beta", self.evaluate())

    def test_missing_xcode_build_is_denied(self):
        self.inventory.xcode = "Xcode 27.0\n"
        self.assertIn("Cannot verify", self.evaluate())

    def test_wrong_runtime_build_is_denied(self):
        self.inventory.runtimes[0]["buildversion"] = "24A5430a"
        self.assertIn("24A5423a", self.evaluate())

    def test_missing_runtime_is_denied(self):
        self.inventory.runtimes = []
        self.assertIn("found: none", self.evaluate())

    def test_ambiguous_same_minor_installs_are_denied(self):
        for build in ("24A5410a", "24A5423a"):
            with self.subTest(build=build):
                other = dict(self.inventory.runtimes[0], buildversion=build, version="27.0.1")
                self.inventory.runtimes = [self.inventory.runtimes[0], other]
                self.assertIn("exactly one", self.evaluate())

    def test_unrelated_or_unavailable_runtimes_do_not_create_ambiguity(self):
        self.inventory.runtimes += [
            dict(self.inventory.runtimes[0], isAvailable=False, buildversion="24A5410a"),
            dict(self.inventory.runtimes[0], version="27.1", buildversion="24B5000a"),
            dict(self.inventory.runtimes[0], identifier="com.apple.CoreSimulator.SimRuntime.tvOS-27-0"),
        ]
        self.assertIsNone(self.evaluate())

    def test_missing_runtime_build_is_denied(self):
        del self.inventory.runtimes[0]["buildversion"]
        self.assertIn("unknown", self.evaluate())

    def test_hidden_conflicting_same_minor_disk_image_is_denied(self):
        self.inventory.images["HIDDEN-IMAGE"] = dict(
            self.inventory.images["PINNED-IMAGE"], version="27.0.1", build="24A5430a")
        self.assertEqual(len(self.inventory.runtimes), 1)
        self.assertIn("disk image", self.evaluate())
        self.assertIn("24A5430a", self.evaluate())

    def test_duplicate_same_build_disk_images_are_denied(self):
        self.inventory.images["DUPLICATE-IMAGE"] = dict(self.inventory.images["PINNED-IMAGE"])
        self.assertIn("exactly one installed", self.evaluate())

    def test_missing_disk_image_metadata_is_denied(self):
        self.inventory.images = {}
        self.assertIn("found: none", self.evaluate())

    def test_unrelated_disk_images_do_not_create_ambiguity(self):
        image = self.inventory.images["PINNED-IMAGE"]
        self.inventory.images["NEWER-IMAGE"] = dict(
            image, runtimeIdentifier=RUNTIME_ID.replace("27-0", "27-1"), version="27.1")
        self.inventory.images["TV-IMAGE"] = dict(
            image, runtimeIdentifier=RUNTIME_ID.replace("iOS", "tvOS"))
        self.assertIsNone(self.evaluate())

    def test_wrong_os_is_denied(self):
        self.assertIn("not 26.4", self.evaluate(COMMAND.replace("OS=27.0", "OS=26.4")))

    def test_wrong_device_type_is_denied(self):
        self.inventory.device["name"] = "iPhone 17 Pro"
        self.inventory.device["deviceTypeIdentifier"] += "-Pro"
        self.assertIn("not CI's iPhone 17", self.evaluate(COMMAND.replace(
            "name=iPhone 17", "name=iPhone 17 Pro")))

    def test_dedicated_worktree_udid_uses_hardware_identity(self):
        command = COMMAND.replace("name=iPhone 17,OS=27.0", "id=WORKTREE-DEVICE")
        self.assertIsNone(self.evaluate(command))

    def test_dedicated_worktree_name_uses_hardware_identity(self):
        self.assertIsNone(self.evaluate(COMMAND.replace("name=iPhone 17", "name=SB-6a40")))

    def test_canonical_name_cannot_hide_wrong_hardware(self):
        self.inventory.canonical_device["deviceTypeIdentifier"] += "-Pro"
        self.assertIn("not CI's", self.evaluate())

    def test_duplicate_canonical_names_are_denied(self):
        self.inventory.device["name"] = "iPhone 17"
        self.assertIn("exactly one available", self.evaluate())

    def test_missing_hardware_identifier_is_denied_even_for_canonical_name(self):
        del self.inventory.canonical_device["deviceTypeIdentifier"]
        self.assertIn("not CI's", self.evaluate())

    def test_unknown_or_expanded_udid_is_denied(self):
        for identifier in ("MISSING-DEVICE", "$SIM_UDID", "`get-sim`"):
            with self.subTest(identifier=identifier):
                self.assertIsNotNone(self.evaluate(COMMAND.replace(
                    "name=iPhone 17,OS=27.0", "id=" + identifier)))

    def test_udid_on_wrong_runtime_is_denied(self):
        self.inventory.devices = {RUNTIME_ID.replace("27-0", "26-4"): [self.inventory.device]}
        self.assertIn("not CI's", self.evaluate(COMMAND.replace(
            "name=iPhone 17,OS=27.0", "id=WORKTREE-DEVICE")))

    def test_missing_destination_name_or_os_is_denied(self):
        for value in ("platform=iOS Simulator", "platform=iOS Simulator,name=iPhone 17"):
            with self.subTest(value=value):
                self.assertIsNotNone(self.evaluate('xcodebuild test -destination "' + value + '"'))

    def test_multiple_destinations_all_must_match(self):
        second = DESTINATION.replace("OS=27.0", "OS=26.4")
        self.assertIsNotNone(self.evaluate(COMMAND + " " + second))

    def test_conflicting_destination_keys_are_denied(self):
        self.assertIsNotNone(self.evaluate(COMMAND.replace("OS=27.0", "OS=27.0,OS=26.4")))

    def test_inline_developer_dir_applies_to_all_probes(self):
        command = 'DEVELOPER_DIR="/Applications/Xcode 27.app/Contents/Developer" ' + COMMAND
        self.assertIsNone(self.evaluate(command))
        self.assertTrue(self.inventory.calls)
        for _, environment in self.inventory.calls:
            self.assertEqual(environment["DEVELOPER_DIR"],
                             "/Applications/Xcode 27.app/Contents/Developer")

    def test_ambiguous_developer_dir_is_denied(self):
        command = "DEVELOPER_DIR=/first DEVELOPER_DIR=/second " + COMMAND
        self.assertIsNotNone(self.evaluate(command))

    def test_failed_inventory_fails_closed(self):
        self.inventory = Mock(side_effect=subprocess.CalledProcessError(1, "xcodebuild"))
        self.assertIn("Cannot verify", self.evaluate())

    def test_malformed_inventory_fails_closed(self):
        self.inventory.runtimes = [None]
        self.assertIn("Cannot verify", self.evaluate())

    def test_missing_workflow_fails_closed(self):
        self.workflow.read_text.side_effect = FileNotFoundError()
        self.assertIn("no fallback pins", self.evaluate())

    def test_malformed_workflow_fails_closed_before_running_tools(self):
        self.workflow.read_text.return_value = "jobs: {}"
        self.assertIn("no fallback pins", self.evaluate())
        self.assertFalse(self.inventory.calls)

    def test_unrelated_commands_and_generic_builds_do_not_read_pins(self):
        self.workflow.read_text.side_effect = FileNotFoundError()
        for command in ("swift test", "xcodebuild -version",
                        'xcodebuild build -destination "generic/platform=iOS Simulator"'):
            with self.subTest(command=command):
                self.assertIsNone(self.evaluate(command))
        self.workflow.read_text.assert_not_called()
        self.assertFalse(self.inventory.calls)

    def test_compatibility_allows_only_explicit_compilation(self):
        for action in ("build", "build-for-testing"):
            with self.subTest(action=action):
                command = "SUPER_IOS_COMPATIBILITY=1 " + COMMAND.replace(
                    "xcodebuild test", "xcodebuild " + action).replace("OS=27.0", "OS=26.4")
                self.assertIsNone(self.evaluate(command))
        self.assertTrue(all(arguments == ["xcodebuild", "-version"]
                            for arguments, _ in self.inventory.calls))

    def test_compatibility_rejects_test_execution(self):
        for action in ("test", "test-without-building"):
            with self.subTest(action=action):
                command = "SUPER_IOS_COMPATIBILITY=1 " + COMMAND.replace("xcodebuild test", "xcodebuild " + action)
                self.assertIn("never test", self.evaluate(command))

    def test_compatibility_rejects_test_action_in_compound_commands(self):
        command = ("SUPER_IOS_COMPATIBILITY=1 xcodebuild build " + DESTINATION
                   + ";xcodebuild test; true")
        self.assertIn("never test", self.evaluate(command))

    def test_compatibility_requires_an_explicit_build_action(self):
        command = "SUPER_IOS_COMPATIBILITY=1 " + COMMAND.replace("xcodebuild test", "xcodebuild")
        self.assertIn("explicit build", self.evaluate(command))

    def test_compatibility_rejects_recording_inline_and_inherited(self):
        command = "SUPER_IOS_COMPATIBILITY=1 " + COMMAND.replace("xcodebuild test", "xcodebuild build")
        for flag in ("SNAPSHOT_RECORD", "TEST_RUNNER_SNAPSHOT_RECORD"):
            with self.subTest(flag=flag):
                self.assertIn("refuses snapshot recording", self.evaluate(flag + "=1 " + command))
                self.assertIn("refuses snapshot recording", self.evaluate(command, {flag: "1"}))

    def test_compatibility_still_requires_pinned_xcode_build(self):
        self.inventory.xcode = "Xcode 27.0\nBuild version 27A5200a\n"
        command = "SUPER_IOS_COMPATIBILITY=1 " + COMMAND.replace("xcodebuild test", "xcodebuild build")
        self.assertIn("27A5252f", self.evaluate(command))

    def test_hook_emits_existing_deny_contract_and_no_allow_output(self):
        payload = json.dumps({"tool_input": {"command": COMMAND}})
        for reason in (None, "Wrong exact build"):
            result = io.StringIO()
            with patch.object(guard.sys, "stdin", io.StringIO(payload)), \
                    patch.object(guard, "evaluate", return_value=reason), \
                    contextlib.redirect_stdout(result):
                guard.main()
            if reason is None:
                self.assertEqual(result.getvalue(), "")
            else:
                self.assertEqual(json.loads(result.getvalue())["hookSpecificOutput"], {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                })


if __name__ == "__main__":
    unittest.main()
