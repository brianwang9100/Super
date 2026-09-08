#!/usr/bin/env python3
"""Attach revision and run identity to an already validated native capture set."""
import argparse
from pathlib import Path
from pipeline import identity, inventories, write_bundle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('shard', choices=['native'])
    parser.add_argument('images', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    write_bundle(args.images, args.output, args.shard, inventories()[args.shard], identity())


if __name__ == '__main__':
    main()
