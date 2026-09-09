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
    def test_existing_build_workflow_exposes_opt_in_same_revision_smoke(self):
        root = Path(__file__).parents[2]
        source = (root / '.github/workflows/ios-build.yml').read_text()
        self.assertIn('ios_26_smoke:', source)
        self.assertIn('default: false', source)
        self.assertIn("if: github.event_name == 'workflow_dispatch' && inputs.ios_26_smoke", source)
        self.assertIn('uses: ./.github/workflows/ios-26-smoke.yml', source)
        child = (root / '.github/workflows/ios-26-smoke.yml').read_text()
        self.assertIn('workflow_call:', child)
        self.assertNotIn('continue-on-error', child)

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

    def launch_diagnostic_outputs(self, simulator, scheme="Super"):
        container = (f"/Users/runner/Library/Developer/CoreSimulator/Devices/{simulator}"
                     f"/data/Containers/Bundle/Application/9163FA43-E6DB-47E7-8284-F5EE1C558E04/{scheme}.app")
        return [container, "245\n", f"S {container}/{scheme}\n", "sample", "", "disk", "memory", "load", "lifecycle"]

    def test_each_launch_has_one_120_second_attempt_without_success_diagnostics(self):
        for scheme, bundle_id in smoke.BUNDLE_IDS.items():
            for configuration in ("Debug", "Release"):
                with self.subTest(scheme=scheme, configuration=configuration):
                    runner, simulator = self.installation_runner(Path("unused"))
                    runner.run.return_value = f"{bundle_id}: 245\n"
                    with patch.object(smoke, "launch_diagnostics") as diagnostics:
                        self.assertEqual(smoke.launch_app(runner, simulator, scheme, configuration), 245)
                    name = f"{scheme}-{configuration}"
                    runner.run.assert_called_once_with(f"launch-{name}", [
                        "xcrun", "simctl", "launch", f"--stdout=unused/{name}-stdout.log",
                        f"--stderr=unused/{name}-stderr.log", simulator, bundle_id,
                    ], timeout=120)
                    diagnostics.assert_not_called()

    def test_launch_and_diagnostics_refuse_unowned_simulators_or_unknown_targets(self):
        runner, simulator = self.installation_runner(Path("unused"))
        for operation in (smoke.launch_app, smoke.launch_diagnostics):
            for device, scheme, configuration in (("booted", "Super", "Debug"),
                                                   (simulator, "Other", "Debug"),
                                                   (simulator, "Super", "Other")):
                with self.subTest(operation=operation.__name__, target=(device, scheme, configuration)):
                    with self.assertRaises(smoke.SmokeError):
                        operation(runner, device, scheme, configuration)
        runner.run.assert_not_called()

    def test_installed_app_path_must_belong_to_exact_owned_simulator_and_target(self):
        _, simulator = self.installation_runner(Path("unused"))
        container = self.launch_diagnostic_outputs(simulator)[0]
        self.assertEqual(smoke.installed_executable(container + "\n", simulator, "Super"), Path(container) / "Super")
        invalid = (container.replace(simulator, "another-device"), container.replace("Super.app", "Other.app"),
                   container.replace("/data/", "/data/../data/"), "/Applications/Super.app", "Super.app",
                   container + "\n/Applications/Other.app", container.replace("9163FA43", "not-a-uuid"))
        for output in invalid:
            with self.subTest(output=output), self.assertRaises(smoke.SmokeError):
                smoke.installed_executable(output, simulator, "Super")

    def test_diagnostic_pid_refuses_missing_ambiguous_or_invalid_results(self):
        self.assertEqual(smoke.diagnostic_pid(" 245\n"), 245)
        for output in ("", "245\n246\n", "245 245", "0", "1", "-2", "245 malicious-argument"):
            with self.subTest(output=output), self.assertRaises(smoke.SmokeError):
                smoke.diagnostic_pid(output)

    def test_process_pattern_escapes_ere_metacharacters_but_not_hyphens(self):
        self.assertEqual(smoke.literal_process_pattern(Path("/a-b/(c)[d]+e?.app/Super")),
                         r"/a-b/\(c\)\[d\]\+e\?\.app/Super")

    def test_launch_diagnostics_are_bounded_app_scoped_and_do_not_relaunch(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            runner, simulator = self.installation_runner(evidence)
            outputs = self.launch_diagnostic_outputs(simulator)
            runner.run.side_effect = outputs
            smoke.launch_diagnostics(runner, simulator, "Super", "Release")
            calls = runner.run.call_args_list
            self.assertEqual(len(calls), 9)
            self.assertTrue(all(item.kwargs == {"timeout": 15} for item in calls))
            self.assertEqual(calls[4].args[1], ["xcrun", "simctl", "io", simulator, "screenshot",
                                              str(evidence / "diagnostic-Super-Release.png")])
            self.assertEqual(calls[0].args[1], ["xcrun", "simctl", "get_app_container", simulator,
                                              "com.brianwang.Super", "app"])
            self.assertEqual(calls[1].args[1], ["pgrep", "-f", "-x",
                                              smoke.literal_process_pattern(Path(outputs[0]) / "Super")])
            self.assertEqual(calls[2].args[1], ["ps", "-p", "245", "-o", "state=", "-o", "comm="])
            self.assertEqual(calls[3].args[1], ["sample", "245", "3", "10", "-file",
                                              str(evidence / "diagnostic-Super-Release-sample.txt")])
            self.assertEqual(calls[8].args[1], [
                "xcrun", "simctl", "spawn", simulator, "log", "show", "--last", "5m", "--style", "compact",
                "--predicate", '(process == "SpringBoard" OR process == "runningboardd" OR process == "launchd") '
                'AND eventMessage CONTAINS "com.brianwang.Super"',
            ])
            self.assertFalse(any("launch" in item.args[1] or "--console" in item.args[1] for item in calls))
            report = json.loads((evidence / "launch-Super-Release-diagnostics.json").read_text())
            self.assertEqual(report["validated_app_pid"], 245)
            self.assertEqual([probe["result"] for probe in report["probes"]], ["collected"] * 9)
            self.assertIn("not startup proof", report["scope"])

    def test_diagnostic_stack_requires_unique_pid_and_exact_non_zombie_app_path(self):
        for variant in ("foreign-container", "ambiguous-pid", "wrong-path", "zombie"):
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as temporary:
                evidence = Path(temporary)
                runner, simulator = self.installation_runner(evidence)
                outputs = self.launch_diagnostic_outputs(simulator)
                if variant == "foreign-container":
                    outputs = ["/Applications/Super.app"] + outputs[4:]
                elif variant == "ambiguous-pid":
                    outputs = outputs[:1] + ["245\n246\n"] + outputs[4:]
                else:
                    identity = "S /Applications/Super.app/Super" if variant == "wrong-path" else outputs[2].replace("S ", "Z ")
                    outputs = outputs[:2] + [identity] + outputs[4:]
                runner.run.side_effect = outputs
                smoke.launch_diagnostics(runner, simulator, "Super", "Release")
                self.assertFalse(any(item.args[1][0] == "sample" for item in runner.run.call_args_list))
                report = json.loads((evidence / "launch-Super-Release-diagnostics.json").read_text())
                self.assertIsNone(report["validated_app_pid"])
                self.assertTrue(any(probe["result"] == "unavailable" for probe in report["probes"]))
                self.assertEqual(runner.run.call_args_list[-1].args[0], "diagnostic-launch-Super-Release-launch-services")

    def test_launch_timeout_remains_failure_even_when_diagnostics_find_app_and_screenshot(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            runner, simulator = self.installation_runner(evidence)
            original = smoke.SmokeError("launch-Super-Release exceeded its deadline")
            runner.run.side_effect = [original] + self.launch_diagnostic_outputs(simulator)
            with self.assertRaises(smoke.SmokeError) as caught:
                smoke.launch_app(runner, simulator, "Super", "Release")
            self.assertIs(caught.exception, original)
            self.assertEqual(runner.stage, "launch-Super-Release")
            self.assertEqual(len([item for item in runner.run.call_args_list if "launch" in item.args[1]]), 1)
            self.assertFalse((evidence / "success.json").exists())

    def test_bad_launch_acknowledgement_still_fails_after_diagnostics(self):
        runner, simulator = self.installation_runner(Path("unused"))
        runner.run.return_value = "com.other.App: 245\n"
        with patch.object(smoke, "launch_diagnostics") as diagnostics:
            with self.assertRaisesRegex(smoke.SmokeError, "simctl did not return"):
                smoke.launch_app(runner, simulator, "Super", "Debug")
        diagnostics.assert_called_once_with(runner, simulator, "Super", "Debug")
        self.assertEqual(runner.stage, "launch-Super-Debug")
        self.assertEqual(runner.run.call_count, 1)

    def test_unavailable_launch_diagnostics_preserve_original_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            runner, simulator = self.installation_runner(evidence)
            original = smoke.SmokeError("launch-Super-Release exceeded its deadline")
            runner.run.side_effect = [original] + [smoke.SmokeError("diagnostic deadline exceeded")] * 6
            with self.assertRaises(smoke.SmokeError) as caught:
                smoke.launch_app(runner, simulator, "Super", "Release")
            self.assertIs(caught.exception, original)
            self.assertEqual(runner.stage, "launch-Super-Release")
            report = json.loads((evidence / "launch-Super-Release-diagnostics.json").read_text())
            self.assertEqual([probe["result"] for probe in report["probes"]], ["unavailable"] * 6)

    def test_launch_diagnostic_write_error_preserves_original_failure(self):
        runner, simulator = self.installation_runner(Path("unused"))
        original = smoke.SmokeError("launch-Super-Release exceeded its deadline")
        runner.run.side_effect = [original] + self.launch_diagnostic_outputs(simulator)
        with patch.object(smoke, "write_json", side_effect=OSError("No space left on device")):
            with self.assertRaises(smoke.SmokeError) as caught:
                smoke.launch_app(runner, simulator, "Super", "Release")
        self.assertIs(caught.exception, original)
        self.assertEqual(runner.stage, "launch-Super-Release")

    def test_completed_cases_survive_later_failure_without_claiming_overall_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            runner, simulator = self.installation_runner(evidence)
            completed = [{"scheme": "Super", "configuration": "Debug", "pid": 245}]
            smoke.record_completed_launches(runner, self.runtime(), completed)
            completed.append({"scheme": "SuperBible", "configuration": "Debug", "pid": 246})
            smoke.record_completed_launches(runner, self.runtime(), completed)
            before = (evidence / "completed-launches.json").read_bytes()
            runner.run.side_effect = smoke.SmokeError("launch-Super-Release exceeded its deadline")
            with patch.object(smoke, "launch_diagnostics"):
                with self.assertRaises(smoke.SmokeError):
                    smoke.launch_app(runner, simulator, "Super", "Release")
            self.assertEqual((evidence / "completed-launches.json").read_bytes(), before)
            report = json.loads(before)
            self.assertEqual(report["launches"], completed)
            self.assertEqual(report["status"], "partial")
            self.assertFalse((evidence / "success.json").exists())

    def test_observation_records_six_fast_samples_across_exact_window_without_real_waits(self):
        runner = Mock()
        runner.clock.side_effect = [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5]
        runner.run.return_value = "S /Applications/Super.app/Super\n"
        wait = Mock()
        self.assertEqual(smoke.observe_process(runner, "Super-Debug", 245, "Super", wait=wait),
                         {"process_samples": 6, "observation_seconds": 5})
        self.assertEqual(wait.call_args_list, [call(1)] * 5)
        self.assertEqual(runner.run.call_args_list, [
            call(f"process-Super-Debug-{index}", ["ps", "-p", "245", "-o", "state=", "-o", "comm="], timeout=10)
            for index in range(6)
        ])

    def observation_runner(self, durations):
        runner = Mock()
        instant = [0]
        durations = iter(durations)

        def process(*_arguments, **_keywords):
            instant[0] += next(durations)
            return "R /Applications/Super.app/Super\n"

        def advance(seconds):
            instant[0] += seconds

        runner.clock.side_effect = lambda: instant[0]
        runner.run.side_effect = process
        return runner, Mock(side_effect=advance)

    def test_slow_first_probe_does_not_count_toward_observation_window(self):
        runner, wait = self.observation_runner([6, 0, 0, 0, 0, 0])
        self.assertEqual(smoke.observe_process(runner, "Super-Debug", 245, "Super", wait=wait),
                         {"process_samples": 6, "observation_seconds": 5})
        self.assertEqual(runner.run.call_count, 6)
        self.assertEqual(wait.call_args_list, [call(1)] * 5)

    def test_probe_started_before_deadline_cannot_be_final_endpoint_even_if_it_completes_late(self):
        runner, wait = self.observation_runner([0.25, 5.25, 0])
        self.assertEqual(smoke.observe_process(runner, "Super-Debug", 245, "Super", wait=wait),
                         {"process_samples": 3, "observation_seconds": 6.25})
        self.assertEqual(runner.run.call_count, 3)
        wait.assert_called_once_with(1)

    def test_observation_fails_immediately_if_process_dies_or_identity_changes(self):
        for output in ("Z /Applications/Super.app/Super", "S /Applications/Other.app/Other", ""):
            with self.subTest(output=output):
                runner = Mock()
                runner.clock.return_value = 0
                runner.run.return_value = output
                wait = Mock()
                with self.assertRaises(smoke.SmokeError):
                    smoke.observe_process(runner, "Super-Debug", 245, "Super", wait=wait)
                runner.run.assert_called_once()
                wait.assert_not_called()

    def test_install_and_diagnostic_timeouts_share_unchanged_global_deadline(self):
        for timeout in (smoke.INSTALL_TIMEOUT_SECONDS, smoke.LAUNCH_TIMEOUT_SECONDS, smoke.DIAGNOSTIC_TIMEOUT_SECONDS):
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
