#!/usr/bin/env python3
"""Build the read-only `bible-text.sqlite` full-text-search database from the
bundled per-book translation JSON.

`bible.read` looks scripture up by *reference*; this database is the substrate for
its sibling, `bible.search` — retrieval by *content*. It is a flat, immutable verse
table plus an FTS5 index, kept deliberately separate from the mutable, sync-targeted
`bible.sqlite` so 124k static verse rows never enter the sync story.

Run once from the package root after the JSON resources change; commit the result:

    python3 Scripts/generate_bible_text_sqlite.py

By default it reads every `<CODE>-<bookID>.json` under `Sources/Bible/Resources/`
and writes `Sources/Bible/Resources/bible-text.sqlite`. Pass explicit paths to
override:

    python3 Scripts/generate_bible_text_sqlite.py <resources_dir> <output_sqlite>

The verse text is **coalesced exactly as Swift's `BibleChapter.coalescedVerses()`
does** (Models/BibleChapter.swift): walk paragraphs in order, skip headings, group
fragments sharing a verse number, join them space-separated, flatten `\n` line
breaks to spaces, ascending verse order. `BibleTextDatabase`'s bundled-consistency
test diffs the shipped rows against that Swift path, so the two must not drift.
"""

import json
import sqlite3
import sys
from pathlib import Path


def coalesce_chapter(paragraphs):
    """One (verse_number, text) pair per verse, mirroring `coalescedVerses()`.

    Headings are skipped; fragments of the same verse number (a verse whose text
    straddles a prose/poetry boundary) are joined with a single space and any
    embedded newline is flattened to a space. Order follows first appearance,
    which the source JSON already emits ascending.
    """
    order = []
    fragments = {}
    for paragraph in paragraphs:
        if paragraph["type"] == "heading":
            continue
        for verse in paragraph["verses"]:
            number = verse["number"]
            if number not in fragments:
                order.append(number)
                fragments[number] = []
            fragments[number].append(verse["text"])
    rows = []
    for number in order:
        text = " ".join(fragments[number]).replace("\n", " ")
        rows.append((number, text))
    return rows


def iter_verse_rows(resources_dir):
    """Yield (translation, bookId, chapter, verse, text) for every bundled book."""
    for json_path in sorted(resources_dir.glob("*-*.json")):
        # `<CODE>-<bookID>.json`, e.g. `KJV-1PE.json`. The bookId itself can
        # contain a hyphen-free 3-char code, so split only on the first hyphen.
        translation = json_path.stem.split("-", 1)[0]
        book = json.loads(json_path.read_text(encoding="utf-8"))
        book_id = book["id"]
        for chapter in book["chapters"]:
            chapter_number = chapter["number"]
            for verse_number, text in coalesce_chapter(chapter["paragraphs"]):
                yield (translation, book_id, chapter_number, verse_number, text)


def build(resources_dir: Path, output_path: Path):
    if output_path.exists():
        output_path.unlink()
    connection = sqlite3.connect(output_path)
    try:
        connection.executescript(
            """
            CREATE TABLE verse (
              id          INTEGER PRIMARY KEY,
              translation TEXT NOT NULL,
              bookId      TEXT NOT NULL,
              chapter     INTEGER NOT NULL,
              verse       INTEGER NOT NULL,
              text        TEXT NOT NULL
            );
            CREATE INDEX verse_on_translation_bookId_chapter
              ON verse(translation, bookId, chapter);
            CREATE VIRTUAL TABLE verse_fts USING fts5(
              text,
              content='verse',
              content_rowid='id',
              tokenize='porter unicode61'
            );
            """
        )
        rows = list(iter_verse_rows(resources_dir))
        connection.executemany(
            "INSERT INTO verse(translation, bookId, chapter, verse, text) "
            "VALUES (?, ?, ?, ?, ?)",
            rows,
        )
        connection.execute(
            "INSERT INTO verse_fts(rowid, text) SELECT id, text FROM verse"
        )
        # Compact the FTS index and reclaim the slack from the dropped rowids so
        # the committed artifact is as small as it can be.
        connection.execute("INSERT INTO verse_fts(verse_fts) VALUES('optimize')")
        connection.commit()
        connection.execute("VACUUM")
        connection.commit()
        return len(rows)
    finally:
        connection.close()


def main(argv):
    script_dir = Path(__file__).resolve().parent
    package_root = script_dir.parent
    default_resources = package_root / "Sources" / "Bible" / "Resources"

    if len(argv) == 1:
        resources_dir = default_resources
        output_path = default_resources / "bible-text.sqlite"
    elif len(argv) == 3:
        resources_dir = Path(argv[1])
        output_path = Path(argv[2])
    else:
        print(__doc__)
        print(f"error: expected 0 or 2 arguments, got {len(argv) - 1}")
        return 2

    if not resources_dir.is_dir():
        print(f"error: resources dir not found: {resources_dir}")
        return 1

    count = build(resources_dir, output_path)
    size_mb = output_path.stat().st_size / (1024 * 1024)
    print(f"wrote {count} verses to {output_path} ({size_mb:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
