"""Deterministic safety checks for the manual iOS 26 startup-only workflow."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, call, patch


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

    def test_each_configuration_boots_dedicated_exact_runtime_with_ten_minute_bound(self):
        simulator = "4B08B54B-F1D1-4A10-81D7-013961E880AD"
        for configuration in ("Debug", "Release"):
            with self.subTest(configuration=configuration):
                runner = Mock()
                runner.created_simulators = set()
                runner.run.side_effect = [simulator + "\n", "", "Finished"]
                self.assertEqual(smoke.boot_simulator(runner, configuration), simulator)
                self.assertEqual(runner.created_simulators, {simulator})
                self.assertEqual(runner.run.call_args_list, [
                    call(f"create-{configuration}", ["xcrun", "simctl", "create",
                         f"IOS26Smoke-{configuration}", "iPhone 17", smoke.RUNTIME_IDENTIFIER]),
                    call(f"boot-{configuration}", ["xcrun", "simctl", "boot", simulator]),
                    call(f"boot-ready-{configuration}", ["xcrun", "simctl", "bootstatus", simulator, "-b"],
                         timeout=600),
                ])

    def test_boot_never_uses_an_unexpected_device_identifier(self):
        runner = Mock()
        runner.run.return_value = "booted"
        with self.assertRaises(smoke.SmokeError):
            smoke.boot_simulator(runner, "Debug")
        self.assertEqual(runner.run.call_count, 1)

    def installation_runner(self, evidence):
        runner = smoke.SmokeRunner(evidence, clock=lambda: 0)
        simulator = "4B08B54B-F1D1-4A10-81D7-013961E880AD"
        runner.created_simulators.add(simulator)
        runner.run = Mock(return_value="")
        return runner, simulator

    def test_each_installation_has_one_ten_minute_attempt_and_no_success_diagnostics(self):
        for scheme in smoke.BUNDLE_IDS:
            for configuration in ("Debug", "Release"):
                with self.subTest(scheme=scheme, configuration=configuration):
                    runner, simulator = self.installation_runner(Path("unused"))
                    app = Path(f"build/{configuration}/{scheme}.app")
                    with patch.object(smoke, "install_diagnostics") as diagnostics:
                        smoke.install_app(runner, simulator, app, scheme, configuration)
                    runner.run.assert_called_once_with(
                        f"install-{scheme}-{configuration}",
                        ["xcrun", "simctl", "install", simulator, str(app)], timeout=600,
                    )
                    diagnostics.assert_not_called()
                    self.assertEqual(runner.deadline, 65 * 60)

    def test_installation_and_diagnostics_refuse_unowned_simulators(self):
        runner, _ = self.installation_runner(Path("unused"))
        for operation in (smoke.install_app, smoke.install_diagnostics):
            with self.subTest(operation=operation.__name__):
                with self.assertRaises(smoke.SmokeError):
                    operation(runner, "booted", Path("Super.app"), "Super", "Debug")
        runner.run.assert_not_called()

    def test_install_diagnostics_are_bounded_and_exclude_unrelated_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            runner, simulator = self.installation_runner(evidence)
            app = evidence / "Super.app"
            smoke.install_diagnostics(runner, simulator, app, "Super", "Debug")
            self.assertEqual(runner.run.call_args_list, [
                call("diagnostic-Super-Debug-disk", ["df", "-k", str(evidence)], timeout=15),
                call("diagnostic-Super-Debug-memory", ["vm_stat"], timeout=15),
                call("diagnostic-Super-Debug-load", ["sysctl", "vm.loadavg"], timeout=15),
                call("diagnostic-Super-Debug-app-size", ["du", "-sk", str(app)], timeout=15),
                call("diagnostic-Super-Debug-app-container", [
                    "xcrun", "simctl", "get_app_container", simulator, "com.brianwang.Super", "app",
                ], timeout=15),
                call("diagnostic-Super-Debug-installer", [
                    "xcrun", "simctl", "spawn", simulator, "log", "show", "--last", "5m",
                    "--style", "compact", "--predicate",
                    'process == "installd" AND eventMessage CONTAINS "com.brianwang.Super"',
                ], timeout=15),
            ])
            report = json.loads((evidence / "install-Super-Debug-diagnostics.json").read_text())
            self.assertEqual(report["simulator"], simulator)
            self.assertEqual(report["bundle_id"], "com.brianwang.Super")
            self.assertEqual([probe["result"] for probe in report["probes"]], ["collected"] * 6)

    def test_install_timeout_stays_failure_after_successful_diagnostics_without_retry(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner, simulator = self.installation_runner(Path(temporary))
            original = smoke.SmokeError("install-Super-Debug exceeded its deadline")
            runner.run.side_effect = [original] + [""] * 6
            with self.assertRaises(smoke.SmokeError) as caught:
                smoke.install_app(runner, simulator, Path("Super.app"), "Super", "Debug")
            self.assertIs(caught.exception, original)
            self.assertEqual(runner.stage, "install-Super-Debug")
            self.assertEqual(runner.run.call_count, 7)
            install_calls = [item for item in runner.run.call_args_list if item.args[0].startswith("install-")]
            self.assertEqual(len(install_calls), 1)

    def test_unavailable_diagnostics_do_not_replace_install_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            runner, simulator = self.installation_runner(evidence)
            original = smoke.SmokeError("install-SuperBible-Release failed with exit code 1")
            runner.run.side_effect = [original] + [smoke.SmokeError("diagnostic deadline exceeded")] * 6
            with self.assertRaises(smoke.SmokeError) as caught:
                smoke.install_app(runner, simulator, Path("SuperBible.app"), "SuperBible", "Release")
            self.assertIs(caught.exception, original)
            self.assertEqual(runner.stage, "install-SuperBible-Release")
            report = json.loads((evidence / "install-SuperBible-Release-diagnostics.json").read_text())
            self.assertEqual([probe["result"] for probe in report["probes"]], ["unavailable"] * 6)
            self.assertEqual(runner.run.call_count, 7)

    def test_diagnostic_write_error_preserves_original_install_error(self):
        runner, simulator = self.installation_runner(Path("unused"))
        original = smoke.SmokeError("install-Super-Debug exceeded its deadline")
        runner.run.side_effect = [original] + [""] * 6
        with patch.object(smoke, "write_json", side_effect=OSError("No space left on device")):
            with self.assertRaises(smoke.SmokeError) as caught:
                smoke.install_app(runner, simulator, Path("Super.app"), "Super", "Debug")
        self.assertIs(caught.exception, original)
        self.assertEqual(runner.stage, "install-Super-Debug")

    def test_install_and_diagnostic_timeouts_share_unchanged_global_deadline(self):
        for timeout in (smoke.INSTALL_TIMEOUT_SECONDS, smoke.DIAGNOSTIC_TIMEOUT_SECONDS):
            with self.subTest(timeout=timeout), tempfile.TemporaryDirectory() as temporary:
                instant = iter((0, 65 * 60 - 8))
                runner = smoke.SmokeRunner(Path(temporary), clock=lambda: next(instant))
                process = Mock(stdout=[], pid=123)
                process.wait.return_value = 0
                with patch.object(smoke.subprocess, "Popen", return_value=process):
                    with patch.object(smoke.threading, "Timer") as timer:
                        runner.run("bounded-command", ["fixture"], timeout=timeout)
                self.assertEqual(timer.call_args.args[0], 8)
                timer.return_value.start.assert_called_once()
                timer.return_value.cancel.assert_called_once()
                self.assertEqual(runner.deadline, 65 * 60)

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
