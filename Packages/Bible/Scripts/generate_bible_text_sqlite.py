#!/usr/bin/env python3
"""Build the read-only `bible-text.sqlite` database from the per-book translation
JSON.

The JSON is **not shipped** in the app — it lives in the test target
(`Tests/BibleTests/Fixtures/Text/`) as the parity oracle the sqlite is generated
from. The committed `bible-text.sqlite` is the sole on-device source of Bible text.

This database is the immutable, prebuilt store for on-device Bible text, kept
deliberately separate from the mutable, sync-targeted `bible.sqlite` so its static
rows never enter the sync story. It carries two layers, both derived here from the
same parsed chapters:

- **Reading** — a `chapter` table whose `json` column holds each chapter's structured
  object (`{number, paragraphs}`) *verbatim*, so Swift's `JSONDecoder` reconstructs
  the identical `BibleChapter`. (Consumed by the chapter reader and `bible.read`.)
  Book *names* stay in `BibleBookCatalog`, so no `book` table is needed here.
- **Search** — a flat, coalesced `verse` table + an FTS5 index, the substrate for
  `bible.search` — retrieval by *content* rather than *reference*.

Run once from the package root after the JSON resources change; commit the result:

    python3 Scripts/generate_bible_text_sqlite.py

By default it reads every `<CODE>-<bookID>.json` under
`Tests/BibleTests/Fixtures/Text/` and writes `Sources/Bible/Resources/bible-text.sqlite`.
Pass explicit paths to override:

    python3 Scripts/generate_bible_text_sqlite.py <json_dir> <output_sqlite>

The structured `chapter.json` is stored unmodified — key order and whitespace are
irrelevant to `JSONDecoder`. The flat verse text is **coalesced exactly as Swift's
`BibleChapter.coalescedVerses()` does** (Models/BibleChapter.swift): walk paragraphs
in order, skip headings, group fragments sharing a verse number, join them
space-separated, flatten `\n` line breaks to spaces, ascending verse order.
`BibleTextDatabase`'s bundled-consistency test diffs the shipped rows against that
Swift path, so the two must not drift.
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


def iter_books(resources_dir):
    """Yield the decoded `(translation, bookId, book)` for every bundled `<CODE>-<bookID>.json`."""
    for json_path in sorted(resources_dir.glob("*-*.json")):
        # `<CODE>-<bookID>.json`, e.g. `KJV-1PE.json`. The bookId itself can
        # contain a hyphen-free 3-char code, so split only on the first hyphen.
        translation = json_path.stem.split("-", 1)[0]
        book = json.loads(json_path.read_text(encoding="utf-8"))
        yield translation, book["id"], book


def build(resources_dir: Path, output_path: Path):
    if output_path.exists():
        output_path.unlink()
    connection = sqlite3.connect(output_path)
    try:
        connection.executescript(
            """
            CREATE TABLE chapter (
              translation TEXT NOT NULL,
              bookId      TEXT NOT NULL,
              number      INTEGER NOT NULL,
              json        TEXT NOT NULL,
              PRIMARY KEY (translation, bookId, number)
            );
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

        chapter_rows = []
        verse_rows = []
        for translation, book_id, book in iter_books(resources_dir):
            for chapter in book["chapters"]:
                number = chapter["number"]
                # Stored verbatim so Swift decodes the identical `BibleChapter`.
                chapter_rows.append(
                    (translation, book_id, number, json.dumps(chapter, ensure_ascii=False))
                )
                for verse_number, text in coalesce_chapter(chapter["paragraphs"]):
                    verse_rows.append((translation, book_id, number, verse_number, text))

        connection.executemany(
            "INSERT INTO chapter(translation, bookId, number, json) VALUES (?, ?, ?, ?)",
            chapter_rows,
        )
        connection.executemany(
            "INSERT INTO verse(translation, bookId, chapter, verse, text) "
            "VALUES (?, ?, ?, ?, ?)",
            verse_rows,
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
        return len(chapter_rows), len(verse_rows)
    finally:
        connection.close()


def main(argv):
    script_dir = Path(__file__).resolve().parent
    package_root = script_dir.parent
    default_json = package_root / "Tests" / "BibleTests" / "Fixtures" / "Text"
    default_output = package_root / "Sources" / "Bible" / "Resources" / "bible-text.sqlite"

    if len(argv) == 1:
        resources_dir = default_json
        output_path = default_output
    elif len(argv) == 3:
        resources_dir = Path(argv[1])
        output_path = Path(argv[2])
    else:
        print(__doc__)
        print(f"error: expected 0 or 2 arguments, got {len(argv) - 1}")
        return 2

    if not resources_dir.is_dir():
        print(f"error: JSON dir not found: {resources_dir}")
        return 1

    chapters, verses = build(resources_dir, output_path)
    size_mb = output_path.stat().st_size / (1024 * 1024)
    print(
        f"wrote {chapters} chapters, {verses} verses "
        f"to {output_path} ({size_mb:.1f} MB)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
