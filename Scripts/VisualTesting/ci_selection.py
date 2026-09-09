#!/usr/bin/env python3
"""Select safe documentation-only capture exemptions and enforce required gates."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT_DOCUMENTS = {'README.md', 'TODO.md', 'AGENTS.md', 'CLAUDE.md'}
SHA = re.compile(r'[0-9a-f]{40}')


def documentation_path(path):
    """Accept only known documentation text, never arbitrary Markdown resources."""
    if (not path or '\\' in path or any(ord(c) < 32 or ord(c) == 127 for c in path)
            or any(part in {'', '.', '..'} for part in path.split('/'))):
        return False
    return path in ROOT_DOCUMENTS or (path.startswith('docs/') and path.endswith('.md'))


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.PIPE)


def select(root, event_name, event, workflow_sha, workflow_ref):
    """Exempt only a proven nonempty docs diff in the exact tested PR merge."""
    if event_name != 'pull_request':
        return 'full', 'Main pushes, manual runs, and other events compare every capture.'
    try:
        pull_request = event['pull_request']
        base = pull_request['base']['sha']
        head = pull_request['head']['sha']
        number = event['number']
        if (type(number) is not int or number <= 0
                or workflow_ref != f'refs/pull/{number}/merge'
                or any(not isinstance(value, str) or not SHA.fullmatch(value)
                       for value in (base, head, workflow_sha))):
            raise ValueError('Invalid PR revision identity')
        actual = git(root, 'rev-parse', 'HEAD').decode().strip()
        parents = git(root, 'show', '-s', '--format=%P', workflow_sha).decode().split()
        if actual != workflow_sha or parents != [base, head]:
            raise ValueError('Checkout does not match the event merge and parents')
        for revision in (base, head):
            git(root, 'cat-file', '-e', f'{revision}^{{commit}}')
        raw = git(root, 'diff', '--no-ext-diff', '--no-textconv', '--no-renames',
                  '--name-only', '-z', base, workflow_sha, '--')
        if not raw:
            return 'full', 'An empty diff does not authorize a capture exemption.'
        if not raw.endswith(b'\0'):
            raise ValueError('Incomplete changed-path data')
        paths = raw[:-1].decode('utf-8').split('\0')
        if not all(documentation_path(path) for path in paths):
            return 'full', 'The diff includes paths outside the documentation allowlist.'
        return 'docs-only', 'Verified nonempty PR merge diff contains only allowlisted documentation.'
    except (KeyError, TypeError, ValueError, OSError, subprocess.CalledProcessError):
        return 'full', 'PR diff provenance is unavailable or invalid; all captures are required.'


def require_gate(scope, discovery, mode, packages, native, event_name):
    """Reject every missing, failed, or unexpected leg outside the explicit exemption."""
    if scope not in {'packages', 'all'}:
        raise ValueError('Unknown capture gate scope')
    if discovery != 'success':
        raise ValueError('Capture guards, discovery, and selection must succeed.')
    if mode not in {'docs-only', 'full'}:
        raise ValueError('Capture selection is missing or unknown.')
    results = [packages] if scope == 'packages' else [packages, native]
    if mode == 'docs-only':
        if event_name != 'pull_request' or any(result != 'skipped' for result in results):
            raise ValueError('Docs-only exemption requires an eligible PR and exactly skipped capture legs.')
        return 'Documentation-only exemption: guards and discovery passed; no screenshots were rendered.'
    if any(result != 'success' for result in results):
        raise ValueError('Every required capture leg must succeed for a full comparison.')
    return 'All required capture legs passed.'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('select')
    gate = commands.add_parser('gate')
    gate.add_argument('--scope', choices=['packages', 'all'], required=True)
    args = parser.parse_args()
    if args.command == 'select':
        try:
            event = json.loads(Path(os.environ.get('GITHUB_EVENT_PATH', '')).read_text())
        except (OSError, ValueError):
            event = None
        mode, reason = select(Path.cwd(), os.environ.get('GITHUB_EVENT_NAME', ''), event,
                              os.environ.get('GITHUB_SHA', ''), os.environ.get('GITHUB_REF', ''))
        # A missing output destination is an infrastructure failure, not an implicit skip.
        with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
            output.write(f'mode={mode}\n')
        print(f'Capture selection: {mode}. {reason}')
    else:
        try:
            message = require_gate(args.scope, os.environ.get('DISCOVERY', ''),
                                   os.environ.get('MODE', ''), os.environ.get('PACKAGES', ''),
                                   os.environ.get('NATIVE', ''), os.environ.get('GITHUB_EVENT_NAME', ''))
        except ValueError as error:
            print(f'::error::{error}', file=sys.stderr)
            raise SystemExit(1) from error
        print(message)
        if summary := os.environ.get('GITHUB_STEP_SUMMARY'):
            with Path(summary).open('a') as output:
                output.write(message + '\n')


if __name__ == '__main__':
    main()
