"""Regression checks for cached renderer integrity and worktree simulator isolation."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from prepare_renderer import validate_checkout
from run import simulator_name


class RendererIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git('init', '-q')
        (self.root / 'Sources').mkdir()
        (self.root / 'Sources/Renderer.swift').write_text('let value = 1\n')
        (self.root / '.gitignore').write_text('*.extra.swift\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null',
                 'commit', '-qm', 'Fixture')
        self.revision = self.git('rev-parse', 'HEAD').decode().strip()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args])

    def test_clean_checkout_passes(self):
        validate_checkout(self.root, self.revision, b'')

    def test_untracked_source_is_rejected(self):
        (self.root / 'Sources/Extra.swift').write_text('let extra = 2\n')
        with self.assertRaises(ValueError):
            validate_checkout(self.root, self.revision, b'')

    def test_ignored_source_is_also_rejected(self):
        (self.root / 'Sources/ignored.extra.swift').write_text('let extra = 2\n')
        with self.assertRaises(ValueError):
            validate_checkout(self.root, self.revision, b'')

    def test_tracked_edit_requires_exact_patch(self):
        (self.root / 'Sources/Renderer.swift').write_text('let value = 3\n')
        with self.assertRaises(ValueError):
            validate_checkout(self.root, self.revision, b'')
        validate_checkout(self.root, self.revision, self.git('diff', '--binary', 'HEAD'))


class SimulatorIdentityTests(unittest.TestCase):
    def test_standard_sibling_worktrees_are_distinct(self):
        first = Path('/repository/.worktrees/first')
        second = Path('/repository/.worktrees/second')
        self.assertNotEqual(simulator_name(first), simulator_name(second))
        self.assertEqual(simulator_name(first), simulator_name(first))

    def test_managed_worktrees_with_same_repo_name_are_distinct(self):
        self.assertNotEqual(simulator_name(Path('/worktrees/first/Super')),
                            simulator_name(Path('/worktrees/second/Super')))
