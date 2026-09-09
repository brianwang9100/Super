"""Deterministic coverage of snapshot pin parsing and Codex/Bash hook contracts."""
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

WORKFLOW = json.dumps({
    "device": "iPhone 17", "ios_version": "27.0", "ios_build": "24A5423a",
    "xcode_version": "27.0", "xcode_build": "27A5252f", "xcodegen_version": "2.45.4",
})
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
    """Canonical JSON is shared by capture, ownership and the hook."""

    def test_exact_builds_are_independent(self):
        self.assertEqual(guard.parse_pin(WORKFLOW), guard.Pin(
            "iPhone 17", "27.0", "24A5423a", "27.0", "27A5252f"))

    def test_missing_or_malformed_fields_fail_closed(self):
        for key in json.loads(WORKFLOW):
            for value in (None, "", "invalid"):
                pin = json.loads(WORKFLOW)
                pin[key] = value
                with self.subTest(key=key, value=value), self.assertRaises(guard.PinError):
                    guard.parse_pin(json.dumps(pin))
        for value in ("not json", "[]", "{}"):
            with self.assertRaises(guard.PinError):
                guard.parse_pin(value)

    def test_checked_in_workflows_share_exact_toolchain(self):
        root = HOOK_PATH.parents[2]
        primary = guard.load_pin()
        for name in ("ios-build.yml", "swift-test.yml", "testflight.yml", "argos.yml", "ios-26-smoke.yml"):
            source = (root / ".github/workflows" / name).read_text()
            self.assertIn('27.0-beta', source)
            self.assertIn(primary.xcode_build, source)


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
        self.assertIn("27.0", self.evaluate())

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

    def test_codex_cmd_payload_reaches_guard(self):
        payload = json.dumps({"tool_input": {"cmd": COMMAND}})
        with patch.object(guard.sys, "stdin", io.StringIO(payload)), \
                patch.object(guard, "evaluate", return_value=None) as evaluate:
            guard.main()
        evaluate.assert_called_once_with(COMMAND)


if __name__ == "__main__":
    unittest.main()
