"""Enforce explicit local recording and comparison policy in simulator processes."""
import unittest
from capture import capture_environment


class RecordingPolicyTests(unittest.TestCase):
    def test_ci_recording_is_refused_before_launch(self):
        for key in ('CI', 'GITHUB_ACTIONS'):
            for value in ('true', '1', 'TRUE'):
                with self.subTest(key=key, value=value), self.assertRaisesRegex(ValueError, 'forbidden'):
                    capture_environment(True, {key: value})

    def test_ci_identity_is_forwarded_into_simulator(self):
        result = capture_environment(False, {'GITHUB_ACTIONS': 'true'})
        self.assertEqual(result['TEST_RUNNER_CI'], 'true')
        self.assertEqual(result['TEST_RUNNER_VISUAL_RECORD'], '0')

    def test_ambient_recording_and_output_cannot_override_driver(self):
        result = capture_environment(False, {'SNAPSHOT_TESTING_RECORD': 'all',
            'TEST_RUNNER_SNAPSHOT_TESTING_RECORD': 'all', 'VISUAL_RECORD': '1',
            'TEST_RUNNER_VISUAL_RECORD': '1', 'SNAPSHOT_OUTPUT_DIR': '/tmp/elsewhere'})
        self.assertNotIn('SNAPSHOT_TESTING_RECORD', result)
        self.assertNotIn('TEST_RUNNER_SNAPSHOT_TESTING_RECORD', result)
        self.assertNotIn('VISUAL_RECORD', result)
        self.assertNotIn('SNAPSHOT_OUTPUT_DIR', result)
        self.assertEqual(result['TEST_RUNNER_VISUAL_RECORD'], '0')

    def test_explicit_local_recording_is_forwarded(self):
        result = capture_environment(True, {})
        self.assertEqual(result['TEST_RUNNER_VISUAL_RECORD'], '1')
        self.assertEqual(result['TEST_RUNNER_CI'], 'false')
