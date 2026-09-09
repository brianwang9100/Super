"""Exercise selection against real Git histories and the required-check executable."""
import itertools
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import ci_selection


SCRIPT = Path(ci_selection.__file__).resolve()
ROOT = SCRIPT.parents[2]


class SelectionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Capture Test')
        self.git('config', 'user.email', 'capture@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        self.git('config', 'core.hooksPath', '/dev/null')
        self.write('docs/existing.md', 'original')
        self.write('Sources/View.swift', 'struct View {}')
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], stderr=subprocess.PIPE).decode().strip()

    def write(self, path, text='changed'):
        destination = self.root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(text)

    def commit(self, allow_empty=False):
        self.git('add', '--all')
        self.git('commit', '-qm', 'Fixture', *(['--allow-empty'] if allow_empty else []))
        return self.git('rev-parse', 'HEAD')

    def merge(self, allow_empty=False):
        self.head = self.commit(allow_empty)
        # A real two-parent Git merge object models GitHub's tested merge ref.
        self.sha = self.git('commit-tree', f'{self.head}^{{tree}}', '-p', self.base,
                            '-p', self.head, '-m', 'PR merge')
        self.git('checkout', '-q', '--detach', self.sha)
        self.event = {'number': 42, 'pull_request': {
            'base': {'sha': self.base}, 'head': {'sha': self.head}}}

    def selection(self, **overrides):
        arguments = dict(root=self.root, event_name='pull_request', event=self.event,
                         workflow_sha=self.sha, workflow_ref='refs/pull/42/merge')
        return ci_selection.select(**{**arguments, **overrides})[0]

    def test_nonempty_document_add_modify_delete_and_root_docs_can_skip(self):
        (self.root / 'docs/existing.md').unlink()
        self.write('docs/nested/new guide.md')
        for path in ci_selection.ROOT_DOCUMENTS:
            self.write(path)
        self.merge()
        self.assertEqual(self.selection(), 'docs-only')

    def test_modified_document_and_fork_event_can_skip(self):
        self.write('docs/existing.md', 'updated')
        self.merge()
        self.event['pull_request']['head']['repo'] = {'fork': True, 'full_name': 'contributor/fork'}
        self.assertEqual(self.selection(), 'docs-only')

    def test_docs_mixed_with_source_requires_full(self):
        self.write('docs/new.md')
        self.write('Sources/View.swift', 'struct ChangedView {}')
        self.merge()
        self.assertEqual(self.selection(), 'full')

    def test_runtime_markdown_assets_workflows_and_unknown_paths_require_full(self):
        for path in ('Packages/Chat/Sources/Chat/Resources/DefaultSystemPrompt.md',
                     'App-SuperBible/Resources/SuperBibleSystemPrompt.md',
                     '.github/workflows/snapshots.yml', '.github/README.md',
                     'Scripts/VisualTesting/package-inventory.json',
                     'Scripts/VisualTesting/simulator-pins.json', 'Packages/Core/Package.swift',
                     'Assets/image.png', 'docs/image.png', 'unknown.md', '.config'):
            with self.subTest(path=path):
                self.git('checkout', '-q', '--detach', self.base)
                self.write('docs/new.md')
                self.write(path)
                self.merge()
                self.assertEqual(self.selection(), 'full')

    def test_source_to_document_rename_cannot_hide_deletion(self):
        self.git('mv', 'Sources/View.swift', 'docs/renamed.md')
        self.merge()
        self.assertEqual(self.selection(), 'full')

    def test_document_to_source_rename_requires_full(self):
        self.git('mv', 'docs/existing.md', 'Sources/FromDocument.swift')
        self.merge()
        self.assertEqual(self.selection(), 'full')

    def test_source_deletion_requires_full(self):
        (self.root / 'Sources/View.swift').unlink()
        self.merge()
        self.assertEqual(self.selection(), 'full')

    def test_control_character_document_name_requires_full(self):
        self.write('docs/new\nfile.md')
        self.merge()
        self.assertEqual(self.selection(), 'full')

    def test_empty_diff_requires_full(self):
        self.merge(allow_empty=True)
        self.assertEqual(self.selection(), 'full')

    def test_main_manual_and_unknown_events_require_full(self):
        self.write('docs/new.md')
        self.merge()
        for name in ('push', 'workflow_dispatch', '', 'pull_request_target'):
            with self.subTest(name=name):
                self.assertEqual(self.selection(event_name=name), 'full')

    def test_missing_malformed_or_mismatched_provenance_requires_full(self):
        self.write('docs/new.md')
        self.merge()
        for change in ({'event': None}, {'event': {}}, {'workflow_sha': ''},
                       {'workflow_sha': self.head}, {'workflow_sha': 'f' * 40},
                       {'workflow_sha': '--help'}, {'workflow_ref': 'refs/heads/main'},
                       {'workflow_ref': 'refs/pull/43/merge'}):
            with self.subTest(change=change):
                self.assertEqual(self.selection(**change), 'full')
        self.event['pull_request']['base']['sha'] = self.head
        self.assertEqual(self.selection(), 'full')

    def test_wrong_checkout_and_advanced_base_event_require_full(self):
        self.write('docs/new.md')
        self.merge()
        self.git('checkout', '-q', '--detach', self.head)
        self.assertEqual(self.selection(), 'full')
        self.git('checkout', '-q', '--detach', self.base)
        self.write('Sources/New.swift')
        advanced_base = self.commit()
        self.git('checkout', '-q', '--detach', self.sha)
        self.event['pull_request']['base']['sha'] = advanced_base
        self.assertEqual(self.selection(), 'full')

    def test_shallow_two_parent_checkout_supports_verified_diff(self):
        self.write('docs/new.md')
        self.merge()
        clone = self.root / 'shallow'
        subprocess.check_call(['git', '-c', 'advice.detachedHead=false', 'clone', '-q',
                               '--depth=2', self.root.as_uri(), str(clone)])
        self.assertEqual(self.selection(root=clone), 'docs-only')

    def test_missing_parent_history_requires_full(self):
        self.write('docs/new.md')
        self.merge()
        clone = self.root / 'shallow'
        subprocess.check_call(['git', '-c', 'advice.detachedHead=false', 'clone', '-q',
                               '--depth=1', self.root.as_uri(), str(clone)])
        self.assertEqual(self.selection(root=clone), 'full')

    def test_failed_diff_and_malformed_diff_fail_closed(self):
        self.write('docs/new.md')
        self.merge()
        actual_git = ci_selection.git
        for output in (subprocess.CalledProcessError(1, ['git', 'diff']), b'docs/no-terminator.md',
                       b'docs/invalid-\xff.md\0'):
            def changed_git(root, *args):
                if args[0] == 'diff':
                    if isinstance(output, Exception):
                        raise output
                    return output
                return actual_git(root, *args)
            with self.subTest(output=output), patch.object(ci_selection, 'git', side_effect=changed_git):
                self.assertEqual(self.selection(), 'full')

    def test_selector_cli_writes_explicit_mode_and_invalid_json_is_full(self):
        self.write('docs/new.md')
        self.merge()
        event_file = self.root / 'event.json'
        output_file = self.root / 'output'
        env = {**os.environ, 'GITHUB_EVENT_NAME': 'pull_request', 'GITHUB_SHA': self.sha,
               'GITHUB_REF': 'refs/pull/42/merge', 'GITHUB_EVENT_PATH': str(event_file),
               'GITHUB_OUTPUT': str(output_file)}
        for body, expected in ((json.dumps(self.event), 'docs-only'), ('{broken', 'full')):
            event_file.write_text(body)
            output_file.write_text('')
            result = subprocess.run([sys.executable, str(SCRIPT), 'select'], cwd=self.root,
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output_file.read_text(), f'mode={expected}\n')


class RequiredGateTests(unittest.TestCase):
    def test_every_result_combination_has_only_two_explicit_success_modes(self):
        states = ('success', 'failure', 'cancelled', 'skipped', '')
        for scope, mode, discovery, packages, native in itertools.product(
                ('packages', 'all'), ('docs-only', 'full', '', 'unknown'), states, states, states):
            expected = 'skipped' if mode == 'docs-only' else 'success'
            passes = (discovery == 'success' and mode in {'docs-only', 'full'}
                      and packages == expected and (scope == 'packages' or native == expected))
            with self.subTest(scope=scope, mode=mode, discovery=discovery, packages=packages, native=native):
                if passes:
                    ci_selection.require_gate(scope, discovery, mode, packages, native, 'pull_request')
                else:
                    with self.assertRaises(ValueError):
                        ci_selection.require_gate(scope, discovery, mode, packages, native, 'pull_request')

    def test_non_pr_event_cannot_use_documentation_exemption(self):
        for event in ('push', 'workflow_dispatch', ''):
            with self.assertRaises(ValueError):
                ci_selection.require_gate('all', 'success', 'docs-only', 'skipped', 'skipped', event)

    def test_actual_gate_executable_reports_success_and_failure(self):
        env = {**os.environ, 'GITHUB_EVENT_NAME': 'pull_request', 'DISCOVERY': 'success',
               'MODE': 'docs-only', 'PACKAGES': 'skipped', 'NATIVE': 'skipped'}
        env.pop('GITHUB_STEP_SUMMARY', None)
        for changes, succeeds in (({}, True), ({'DISCOVERY': 'failure'}, False),
                                  ({'MODE': ''}, False), ({'PACKAGES': 'cancelled'}, False),
                                  ({'MODE': 'full'}, False),
                                  ({'MODE': 'full', 'PACKAGES': 'success', 'NATIVE': 'success'}, True)):
            result = subprocess.run([sys.executable, str(SCRIPT), 'gate', '--scope', 'all'],
                                    env={**env, **changes}, capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)

    def test_discovery_assignment_propagates_failure_before_output(self):
        workflow = (ROOT / '.github/workflows/snapshots.yml').read_text()
        step = workflow.split('name: Validate and discover package capture owners\n', 1)[1]
        script = step.split('        run: |\n', 1)[1].split('\n\n', 1)[0]
        script = '\n'.join(line.removeprefix('          ') for line in script.splitlines())
        script = script.replace('python3 Scripts/VisualTesting/discover.py', 'exit 17')
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'output'
            result = subprocess.run(['bash', '-e', '-c', script],
                                    env={**os.environ, 'GITHUB_OUTPUT': str(output)}, capture_output=True)
            self.assertEqual(result.returncode, 17)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
