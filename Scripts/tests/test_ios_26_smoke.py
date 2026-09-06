"""Deterministic safety checks for the manual iOS 26 startup-only workflow."""

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("ios_26_smoke", Path(__file__).parents[1] / "ios_26_smoke.py")
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)


class IOS26SmokeTests(unittest.TestCase):
    def runtime(self):
        return {"identifier": smoke.RUNTIME_IDENTIFIER, "version": "26.0",
                "buildversion": "23A343", "isAvailable": True}

    def test_exact_runtime_is_selected_even_when_27_is_installed(self):
        runtime = self.runtime()
        self.assertEqual(smoke.select_runtime({"runtimes": [runtime, {
            "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "isAvailable": True
        }]}), runtime)

    def test_wrong_runtime_build_is_rejected(self):
        runtime = self.runtime()
        runtime["buildversion"] = "wrong"
        with self.assertRaises(smoke.SmokeError):
            smoke.select_runtime({"runtimes": [runtime]})

    def test_newer_26_runtime_is_not_substituted(self):
        runtime = self.runtime()
        runtime.update(identifier="com.apple.CoreSimulator.SimRuntime.iOS-26-4", version="26.4")
        with self.assertRaises(smoke.SmokeError):
            smoke.select_runtime({"runtimes": [runtime]})

    def test_ambiguous_or_unavailable_runtime_is_rejected(self):
        with self.assertRaises(smoke.SmokeError):
            smoke.select_runtime({"runtimes": [self.runtime(), self.runtime()]})
        runtime = self.runtime()
        runtime["isAvailable"] = False
        with self.assertRaises(smoke.SmokeError):
            smoke.select_runtime({"runtimes": [runtime]})

    def test_export_requires_one_real_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(smoke.SmokeError):
                smoke.select_export(root)
            bundle = root / "iossimulator_26.exportedBundle"
            bundle.mkdir()
            self.assertEqual(smoke.select_export(root), bundle)
            (root / "other.exportedBundle").mkdir()
            with self.assertRaises(smoke.SmokeError):
                smoke.select_export(root)

    def test_export_does_not_follow_an_external_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            export = root / "exports"
            export.mkdir()
            external = root / "external"
            external.mkdir()
            (export / "linked.exportedBundle").symlink_to(external, target_is_directory=True)
            with self.assertRaises(smoke.SmokeError):
                smoke.select_export(export)

    def binary_fixture(self):
        return ({"CFBundleIdentifier": "com.brianwang.Super", "CFBundleExecutable": "Super", "MinimumOSVersion": "26.0"},
                "Load command 9\n      cmd LC_BUILD_VERSION\n platform IOSSIMULATOR\n    minos 26.0\n      sdk 27.0\n")

    def test_binary_preserves_26_minimum_with_27_sdk(self):
        smoke.validate_binary(*self.binary_fixture(), "Super")

    def test_binary_rejects_raised_minimum_in_plist_or_macho(self):
        info, commands = self.binary_fixture()
        info["MinimumOSVersion"] = "27.0"
        with self.assertRaises(smoke.SmokeError):
            smoke.validate_binary(info, commands, "Super")
        info, commands = self.binary_fixture()
        with self.assertRaises(smoke.SmokeError):
            smoke.validate_binary(info, commands.replace("minos 26.0", "minos 27.0"), "Super")

    def test_binary_rejects_old_sdk_or_wrong_target(self):
        info, commands = self.binary_fixture()
        with self.assertRaises(smoke.SmokeError):
            smoke.validate_binary(info, commands.replace("sdk 27.0", "sdk 26.4"), "Super")
        with self.assertRaises(smoke.SmokeError):
            smoke.validate_binary(info, commands, "SuperBible")

    def test_launch_must_return_exact_bundle_and_valid_pid(self):
        self.assertEqual(smoke.launch_pid("com.brianwang.Super: 245\n", "com.brianwang.Super"), 245)
        for output in ("com.other.App: 245", "com.brianwang.Super: 0", ""):
            with self.assertRaises(smoke.SmokeError):
                smoke.launch_pid(output, "com.brianwang.Super")

    def test_process_liveness_rejects_zombie_or_reused_pid(self):
        smoke.validate_process("S /Applications/Super.app/Super\n", "Super")
        for output in ("Z /Applications/Super.app/Super", "S /Applications/Other.app/Other", ""):
            with self.assertRaises(smoke.SmokeError):
                smoke.validate_process(output, "Super")

    def test_commands_only_build_apps_and_never_execute_tests(self):
        for scheme in ("Super", "SuperBible"):
            for configuration in ("Debug", "Release"):
                command = smoke.build_command(Path("build/ios-26-smoke"), scheme, configuration, "dedicated-udid")
                self.assertEqual(command[:2], ["xcodebuild", "build"])
                self.assertNotIn("test", command)
                self.assertNotIn("test-without-building", command)
                self.assertIn("platform=iOS Simulator,id=dedicated-udid", command)
                self.assertIn("CODE_SIGNING_ALLOWED=NO", command)

    def test_runner_disables_every_recording_environment_seam(self):
        with patch.dict(os.environ, {"SNAPSHOT_RECORD": "1", "TEST_RUNNER_SNAPSHOT_RECORD": "1"}):
            runner = smoke.SmokeRunner(Path("unused"), clock=lambda: 0)
        for prefix in ("", "TEST_RUNNER_", "SIMCTL_CHILD_"):
            self.assertEqual(runner.environment[prefix + "SNAPSHOT_RECORD"], "0")
            self.assertEqual(runner.environment[prefix + "SNAPSHOT_TESTING_RECORD"], "never")
        self.assertEqual(runner.environment["SUPER_IOS_COMPATIBILITY"], "1")

    def test_overall_deadline_prevents_another_process(self):
        instant = iter((0, 65 * 60 + 1))
        runner = smoke.SmokeRunner(Path("unused"), clock=lambda: next(instant))
        with patch.object(smoke.subprocess, "Popen") as process:
            with self.assertRaises(smoke.SmokeError):
                runner.run("late-command", ["xcodebuild", "-version"])
            process.assert_not_called()


if __name__ == "__main__":
    unittest.main()
