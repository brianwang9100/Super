#!/usr/bin/env python3
"""Discover every package capture owner and reject untracked/missing suites."""
import json
from capture import discover_suites
from pipeline import ROOT, PACKAGES, inventories


def main():
    folders = ROOT.glob('Packages/*/Tests/*/UI/Snapshots')
    packages = sorted({folder.parts[-5] for folder in folders if folder.is_dir()})
    if set(packages) != set(PACKAGES):
        raise ValueError(f'Update the complete capture inventory for package owners: {packages}')
    rows = inventories()
    for package in packages:
        discover_suites(ROOT, package)
        if not rows[package]:
            raise ValueError(f'Empty visual inventory for {package}')
    print(json.dumps(packages))


if __name__ == '__main__':
    main()
