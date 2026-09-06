#!/usr/bin/env python3
"""Own one on-demand simulator per Git worktree and clean up recorded orphans."""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid


class LifecycleError(Exception):
    """An ownership or inventory error that must not trigger deletion."""


def command(args):
    return subprocess.run(args, check=True, text=True, capture_output=True,
                          timeout=120).stdout.strip()


def exists(path):
    """Do not mistake inaccessible paths or dangling symlinks for deletion."""
    try:
        path.lstat()
        return True
    except FileNotFoundError:
        return False


def atomic_json(path, value):
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.registry-')
    try:
        with os.fdopen(fd, 'w') as handle:
            json.dump(value, handle, indent=2)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class Simulators:
    """Serialize association and cleanup using state in the common Git directory."""

    def __init__(self, repo, run=command):
        self.run = run
        self.repo = Path(run(['git', '-C', str(repo), 'rev-parse', '--show-toplevel'])).resolve()
        self.common = Path(self.git('rev-parse', '--path-format=absolute', '--git-common-dir')).resolve()
        self.directory = self.common / 'worktree-simulators'
        self.registry = self.directory / 'registry.json'
        self.namespace = hashlib.sha256(str(self.common).encode()).hexdigest()[:12]

    def git(self, *args):
        return self.run(['git', '-C', str(self.repo), *args])

    @contextmanager
    def locked(self):
        self.directory.mkdir(exist_ok=True)
        with (self.directory / 'lock').open('a') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            yield

    def name(self, token):
        return f'SuperWT-{self.namespace}-{token}'

    def load(self):
        if not exists(self.registry):
            return {'version': 1, 'owners': {}}
        state = json.loads(self.registry.read_text())
        if not isinstance(state, dict) or state.get('version') != 1 or not isinstance(state.get('owners'), dict):
            raise LifecycleError('Unsupported or corrupt simulator registry')
        for token, entry in state['owners'].items():
            if str(uuid.UUID(token)) != token or not isinstance(entry, dict):
                raise LifecycleError('Invalid owner token')
            if entry.get('name') != self.name(token):
                raise LifecycleError('Registry contains an invalid managed simulator name')
            for key in ('worktree', 'admin'):
                if not isinstance(entry.get(key), str) or not Path(entry[key]).is_absolute():
                    raise LifecycleError(f'Invalid {key} path')
            if not Path(entry['admin']).resolve().is_relative_to(self.common):
                raise LifecycleError('Git admin directory is outside this repository')
            if 'udid' not in entry:
                raise LifecycleError('Registry is missing simulator identity')
            if entry['udid'] is not None:
                if not isinstance(entry['udid'], str):
                    raise LifecycleError('Invalid simulator UUID')
                uuid.UUID(entry['udid'])
        return state

    def devices(self):
        data = json.loads(self.run(['xcrun', 'simctl', 'list', 'devices', '--json']))
        if not isinstance(data, dict) or not isinstance(data.get('devices'), dict):
            raise LifecycleError('Invalid simulator inventory')
        result = {}
        for runtime, devices in data['devices'].items():
            if not isinstance(devices, list):
                raise LifecycleError('Invalid simulator inventory')
            for device in devices:
                if not isinstance(device, dict) or not all(isinstance(device.get(k), str) for k in ('udid', 'name', 'state')):
                    raise LifecycleError('Invalid simulator identity')
                uuid.UUID(device['udid'])
                if device['udid'] in result:
                    raise LifecycleError('Duplicate simulator UUID in inventory')
                result[device['udid']] = dict(device, runtime=runtime)
        return result

    def profile(self):
        """Read the existing CI literals; fail rather than fall back to stale pins."""
        text = (self.repo / '.github/workflows/ios-build.yml').read_text()
        def one(pattern):
            matches = set(re.findall(pattern, text))
            if len(matches) != 1:
                raise LifecycleError('Cannot resolve a unique simulator pin from CI')
            return matches.pop()
        version = one(r'simctl\s+list\s+devices\s+--json\s+"iOS\s+([0-9.]+)"')
        build = one(r'RUNTIME_BUILD="([0-9A-Za-z]+)"')
        model = one(r'\.get\("name"\)\s*==\s*"([^"]+)"')
        xcode = one(r'xcode-version:\s*"([0-9.]+)"')
        if f'Xcode {xcode}\n' not in self.run(['xcodebuild', '-version']) + '\n':
            raise LifecycleError(f'Select CI Xcode {xcode} before creating a simulator')
        runtimes = json.loads(self.run(['xcrun', 'simctl', 'list', 'runtimes', '--json']))['runtimes']
        matches = [r for r in runtimes if r.get('isAvailable') and
                   (r.get('version') == version or r.get('version', '').startswith(version + '.'))
                   and '.iOS-' in r.get('identifier', '')]
        if len(matches) != 1 or matches[0].get('buildversion') != build:
            raise LifecycleError(f'Install only CI iOS {version} build {build} for that minor')
        types = json.loads(self.run(['xcrun', 'simctl', 'list', 'devicetypes', '--json']))['devicetypes']
        models = [d['identifier'] for d in types if d.get('name') == model]
        if len(models) != 1:
            raise LifecycleError(f'Cannot resolve device type {model}')
        return matches[0]['identifier'], models[0]

    def device_for(self, entry, devices):
        if entry['udid'] is not None:
            device = devices.get(entry['udid'])
            if device is not None and device['name'] != entry['name']:
                raise LifecycleError('Recorded simulator was renamed; ownership needs inspection')
            if device is None and any(d['name'] == entry['name'] for d in devices.values()):
                raise LifecycleError('Managed name exists with an unexpected UUID')
            return device
        matches = [d for d in devices.values() if d['name'] == entry['name']]
        if len(matches) > 1:
            raise LifecycleError('Ambiguous pending simulator creation')
        return matches[0] if matches else None

    def ensure(self):
        with self.locked():
            state = self.load()
            runtime, model = self.profile()
            admin = Path(self.git('rev-parse', '--absolute-git-dir')).resolve()
            marker = admin / 'super-simulator-owner'
            if not exists(marker):
                marker.write_text(str(uuid.uuid4()) + '\n')
            token = marker.read_text().strip()
            uuid.UUID(token)
            entry = state['owners'].get(token)
            devices = self.devices()
            if entry is None:
                entry = {'worktree': str(self.repo), 'admin': str(admin),
                         'name': self.name(token), 'udid': None}
                if any(d['name'] == entry['name'] for d in devices.values()):
                    raise LifecycleError('Unregistered simulator already uses the managed name')
            elif entry['admin'] != str(admin):
                raise LifecycleError('Owner token belongs to a different Git admin directory')
            entry['worktree'] = str(self.repo)
            device = self.device_for(entry, devices)
            if device is not None:
                if device.get('deviceTypeIdentifier') != model or device['runtime'] != runtime or not device.get('isAvailable'):
                    raise LifecycleError('Owned simulator does not match CI; inspect before replacing it')
                entry['udid'] = device['udid']
            else:
                # Journal intent before creation, including after an externally deleted device.
                entry['udid'] = None
                state['owners'][token] = entry
                atomic_json(self.registry, state)
                entry['udid'] = self.run(['xcrun', 'simctl', 'create', entry['name'], model, runtime])
                uuid.UUID(entry['udid'])
            state['owners'][token] = entry
            atomic_json(self.registry, state)
            return entry['udid']

    def owner_path(self, token, entry, owners):
        """Keep existing paths, and follow a moved worktree's stable Git identity."""
        path = Path(entry['worktree'])
        admin = Path(entry['admin'])
        marker = admin / 'super-simulator-owner'
        if exists(marker):
            current_token = marker.read_text().strip()
            if current_token != token:
                replacement = owners.get(current_token)
                # Git can reuse an admin directory after worktree removal. Only a
                # separately registered, verified live owner proves that reuse.
                if replacement is None or replacement['admin'] != str(admin):
                    raise LifecycleError('Owner metadata changed; refusing cleanup')
                backlink = Path((admin / 'gitdir').read_text().strip())
                if not backlink.is_absolute() or backlink.name != '.git':
                    raise LifecycleError('Invalid replacement worktree backlink')
                replacement_path = backlink.parent
                if not exists(replacement_path):
                    raise LifecycleError('Cannot verify replacement worktree')
                actual = Path(self.run(['git', '-C', str(replacement_path), 'rev-parse', '--absolute-git-dir'])).resolve()
                if actual != admin:
                    raise LifecycleError('Replacement worktree identity does not match')
                replacement['worktree'] = str(replacement_path)
                if exists(path) and path != replacement_path:
                    return path
                return None
        if exists(path):
            return path
        if not exists(admin):
            return None
        if marker.read_text().strip() != token:
            raise LifecycleError('Owner metadata changed; refusing cleanup')
        backlink = Path((admin / 'gitdir').read_text().strip())
        if not backlink.is_absolute() or backlink.name != '.git':
            raise LifecycleError('Invalid worktree backlink')
        moved = backlink.parent
        if exists(moved):
            actual = Path(self.run(['git', '-C', str(moved), 'rev-parse', '--absolute-git-dir'])).resolve()
            if actual != admin:
                raise LifecycleError('Moved worktree identity does not match')
            return moved
        return None

    def cleanup(self, apply=False):
        with self.locked():
            state = self.load()
            devices = self.devices()
            # Validate every owner/device before any destructive operation.
            for token, entry in state['owners'].items():
                self.owner_path(token, entry, state['owners'])
                self.device_for(entry, devices)
            report = {'apply': apply, 'retained': 0, 'orphans': [], 'deleted': [], 'missing': []}
            for token, entry in list(state['owners'].items()):
                path = self.owner_path(token, entry, state['owners'])
                if path is not None:
                    report['retained'] += 1
                    entry['worktree'] = str(path)
                    continue
                device = self.device_for(entry, self.devices())
                report['orphans'].append(dict(entry))
                if not apply:
                    continue
                if device is not None:
                    # Bind a recovered pending creation to its UUID before any mutation.
                    entry['udid'] = device['udid']
                    atomic_json(self.registry, state)
                    if self.owner_path(token, entry, state['owners']) is not None:
                        raise LifecycleError('Owner reappeared during cleanup; retry inventory')
                    if device['state'] != 'Shutdown':
                        self.run(['xcrun', 'simctl', 'shutdown', device['udid']])
                    # Recheck after shutdown; a move must not cause simulator deletion.
                    if self.owner_path(token, entry, state['owners']) is not None:
                        raise LifecycleError('Owner reappeared during cleanup; simulator retained')
                    current = self.device_for(entry, self.devices())
                    if current is not None:
                        self.run(['xcrun', 'simctl', 'delete', current['udid']])
                        report['deleted'].append(current['udid'])
                else:
                    report['missing'].append(entry['udid'])
                del state['owners'][token]
                atomic_json(self.registry, state)
            if apply:
                atomic_json(self.registry, state)
            return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['ensure', 'cleanup'])
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    parser.add_argument('--apply', action='store_true', help='Delete recorded orphan simulators (cleanup only)')
    args = parser.parse_args()
    if args.apply and args.action != 'cleanup':
        parser.error('--apply is only valid with cleanup')
    try:
        manager = Simulators(args.repo)
        if args.action == 'ensure':
            print(manager.ensure())
        else:
            print(json.dumps(manager.cleanup(apply=args.apply), indent=2))
    except (LifecycleError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f'worktree simulator: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
