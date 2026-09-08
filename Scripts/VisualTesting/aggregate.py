#!/usr/bin/env python3
"""Create a PNG-only upload directory from this run's five verified artifacts."""
import argparse
from pathlib import Path
from pipeline import aggregate, identity, inventories


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    expected = inventories()
    aggregate(args.artifacts, args.output, expected, identity())
    print(f'Validated {sum(len(rows) for rows in expected.values())} captures across {len(expected)} shards')


if __name__ == '__main__':
    main()
