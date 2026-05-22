#!/usr/bin/env python3
"""Convert a public-domain Bible translation's USFM into per-book JSON.

The Bible applet bundles four public-domain, Protestant-canon translations.
Download each USFM bundle before running:

    WEB  curl -sL -o web.zip https://ebible.org/Scriptures/engwebp_usfm.zip
    KJV  curl -sL -o kjv.zip https://ebible.org/Scriptures/eng-kjv2006_usfm.zip
    ASV  curl -sL -o asv.zip https://ebible.org/Scriptures/eng-asv_usfm.zip
    BSB  curl -sL -o bsb.zip https://bereanbible.com/bsb_usfm.zip

Unzip each into its own directory, then run once per translation:

    python3 generate_translation_json.py <CODE> <usfm_dir> <output_dir>

`<CODE>` is the translation's short code (`WEB`, `KJV`, `ASV`, `BSB`) — it
only names the output files and is not read from the USFM. Emits one
`<CODE>-<BOOKID>.json` per canonical book into <output_dir>; non-canonical
files (front matter, intros) are skipped. The JSON schema is a discriminated
union of paragraph types decoded by `BibleBook`:

    { "id", "name", "testament", "chapters": [
        { "number", "paragraphs": [
            { "type": "heading", "text" }
          | { "type": "prose",  "verses": [ { "number", "text" } ] }
          | { "type": "poetry", "verses": [ { "number", "text" } ] } ] } ] }

A verse may appear in more than one consecutive paragraph: USFM lets a verse
straddle a paragraph or poetry break, and each fragment is emitted under the
same verse number — the renderer shows the verse number once per fragment.
"""
import json
import re
import sys
from pathlib import Path

OLD_TESTAMENT = (
    "GEN EXO LEV NUM DEU JOS JDG RUT 1SA 2SA 1KI 2KI 1CH 2CH EZR NEH EST JOB "
    "PSA PRO ECC SNG ISA JER LAM EZK DAN HOS JOL AMO OBA JON MIC NAM HAB ZEP "
    "HAG ZEC MAL"
).split()
NEW_TESTAMENT = (
    "MAT MRK LUK JHN ACT ROM 1CO 2CO GAL EPH PHP COL 1TH 2TH 1TI 2TI TIT PHM "
    "HEB JAS 1PE 2PE 1JN 2JN 3JN JUD REV"
).split()
TESTAMENT = {b: "OT" for b in OLD_TESTAMENT} | {b: "NT" for b in NEW_TESTAMENT}

# Canonical display names per book ID, matching `BibleBookCatalog.standard`.
# Used in preference to the source USFM's `\h` field so a translation that
# spells a book differently (BSB uses `\h Psalm` rather than `Psalms`) still
# lines up with the catalog that the picker and tests are keyed against.
CANONICAL_NAMES = {
    "GEN": "Genesis", "EXO": "Exodus", "LEV": "Leviticus", "NUM": "Numbers",
    "DEU": "Deuteronomy", "JOS": "Joshua", "JDG": "Judges", "RUT": "Ruth",
    "1SA": "1 Samuel", "2SA": "2 Samuel", "1KI": "1 Kings", "2KI": "2 Kings",
    "1CH": "1 Chronicles", "2CH": "2 Chronicles", "EZR": "Ezra",
    "NEH": "Nehemiah", "EST": "Esther", "JOB": "Job", "PSA": "Psalms",
    "PRO": "Proverbs", "ECC": "Ecclesiastes", "SNG": "Song of Solomon",
    "ISA": "Isaiah", "JER": "Jeremiah", "LAM": "Lamentations",
    "EZK": "Ezekiel", "DAN": "Daniel", "HOS": "Hosea", "JOL": "Joel",
    "AMO": "Amos", "OBA": "Obadiah", "JON": "Jonah", "MIC": "Micah",
    "NAM": "Nahum", "HAB": "Habakkuk", "ZEP": "Zephaniah", "HAG": "Haggai",
    "ZEC": "Zechariah", "MAL": "Malachi", "MAT": "Matthew", "MRK": "Mark",
    "LUK": "Luke", "JHN": "John", "ACT": "Acts", "ROM": "Romans",
    "1CO": "1 Corinthians", "2CO": "2 Corinthians", "GAL": "Galatians",
    "EPH": "Ephesians", "PHP": "Philippians", "COL": "Colossians",
    "1TH": "1 Thessalonians", "2TH": "2 Thessalonians", "1TI": "1 Timothy",
    "2TI": "2 Timothy", "TIT": "Titus", "PHM": "Philemon", "HEB": "Hebrews",
    "JAS": "James", "1PE": "1 Peter", "2PE": "2 Peter", "1JN": "1 John",
    "2JN": "2 John", "3JN": "3 John", "JUD": "Jude", "REV": "Revelation",
}

PROSE_MARKERS = {"p", "m", "nb", "pi1", "mi", "li1", "li2", "ili", "pc", "pmo"}
POETRY_MARKERS = {"q1", "q2", "qr"}
# Headings that follow their chapter: psalm titles (\d), speaker labels (\sp),
# the five "BOOK N" dividers of Psalms (\ms / \ms1), in-chapter section
# headings (\s1, \s2), acrostic-stanza letters in Psalm 119 (\qa), and the
# scripture-range subheadings under major sections (\mr).
HEADING_MARKERS = {"d", "sp", "is1", "ms", "ms1", "s1", "s2", "qa", "mr"}

_FOOTNOTE = re.compile(r"\\f .+?\\f\*")
_CROSSREF = re.compile(r"\\x .+?\\x\*")
_WORD = re.compile(r"\\\+?w ([^\\|]*)(?:\|[^\\]*)?\\\+?w\*")
_CLOSING_MARKER = re.compile(r"\\\+?[a-z]+\d?\*")
_OPENING_MARKER = re.compile(r"\\\+?[a-z]+\d? ?")
_SPACES = re.compile(r"[ \t]+")
_LINE = re.compile(r"\\(\+?[a-z]+\d?) ?(.*)")
# BSB-style USFM packs many verse markers per source line, e.g.
# `\p \v 1 text \v 2 text \v 3 text`, and the chapter+psalm-superscription
# pattern `\d \v 1 A Psalm of David.`. Inserting a newline before every
# `\v <digit>` token normalises the input so each verse marker starts its
# own logical line — the main loop then handles them one at a time via the
# existing `\v` branch, without any marker-by-marker inline-verse special
# case. The lookahead requires `\s+\d` so unrelated markers that begin with
# `v` (e.g. `\vp ... \vp*` for verse publication info) are not split.
_INLINE_VERSE = re.compile(r"\\v(?=\s+\d)")


def clean(text: str) -> str:
    """Strip USFM inline markup, leaving plain reading text.

    Footnotes and cross-references are dropped entirely; word-level Strong's
    annotations and other character markers are unwrapped to their content.
    The KJV2006 source embeds literal `¶` pilcrows as paragraph marks — those
    are a typographic device, not reading text, so they are dropped too.
    """
    text = _FOOTNOTE.sub("", text)
    text = _CROSSREF.sub("", text)
    text = _WORD.sub(r"\1", text)
    text = _CLOSING_MARKER.sub("", text)
    text = _OPENING_MARKER.sub("", text)
    text = text.replace("¶", "")
    return _SPACES.sub(" ", text).strip()


def parse_book(usfm: str) -> dict:
    # Normalise BSB-style multi-verse lines so every `\v N` starts its own
    # logical line. A no-op for sources that already put one verse per line.
    usfm = _INLINE_VERSE.sub(r"\n\\v", usfm)
    book = {"id": None, "name": None, "testament": None, "chapters": []}
    chapter = None
    para = None
    kind = None
    verse_num = None

    def flush_para():
        nonlocal para
        if para is not None and para["verses"]:
            chapter["paragraphs"].append(para)
        para = None

    def add_text(text: str, *, line_break: bool):
        if not text:
            return
        verses = para["verses"]
        if verses and verses[-1]["number"] == verse_num:
            sep = "\n" if line_break else " "
            verses[-1]["text"] = (verses[-1]["text"] + sep + text).strip()
        else:
            verses.append({"number": verse_num, "text": text})

    for raw in usfm.splitlines():
        line = raw.rstrip()
        if not line:
            continue
        match = _LINE.match(line)
        if match is None:
            if chapter is not None and para is not None and verse_num is not None:
                add_text(clean(line), line_break=(kind == "poetry"))
            elif line.strip():
                print(f"warning: dropped stray line: {line!r}", file=sys.stderr)
            continue
        marker, rest = match.group(1), match.group(2)

        if marker == "id":
            book["id"] = rest.split()[0]
        elif marker == "h":
            book["name"] = rest.strip()
        elif marker == "c":
            flush_para()
            chapter = {"number": int(re.match(r"\d+", rest).group()), "paragraphs": []}
            book["chapters"].append(chapter)
            kind = verse_num = None
        elif chapter is None:
            continue
        elif marker in PROSE_MARKERS:
            flush_para()
            para, kind = {"type": "prose", "verses": []}, "prose"
            if verse_num is not None:
                add_text(clean(rest), line_break=False)
        elif marker in POETRY_MARKERS:
            if para is None or kind != "poetry":
                flush_para()
                para, kind = {"type": "poetry", "verses": []}, "poetry"
            if verse_num is not None:
                add_text(clean(rest), line_break=True)
        elif marker in HEADING_MARKERS:
            flush_para()
            kind = None
            # A heading marker whose verse marker was split off (e.g. BSB's
            # `\d \v 1 A Psalm of David.` becomes a bare `\d` line plus a
            # `\v 1 ...` line) leaves an empty heading — suppress those so
            # the reader doesn't render a blank section break.
            heading_text = clean(rest)
            if heading_text:
                chapter["paragraphs"].append({"type": "heading", "text": heading_text})
        elif marker == "b":
            flush_para()
            kind = None
        elif marker == "v":
            num, _, text = rest.partition(" ")
            verse_num = int(re.match(r"\d+", num).group())
            if para is None:
                para, kind = {"type": "prose", "verses": []}, "prose"
            add_text(clean(text), line_break=(kind == "poetry"))

    flush_para()
    book["testament"] = TESTAMENT.get(book["id"])
    # Override the source USFM's `\h` with the canonical display name when the
    # book is in the standard 66-book canon — keeps every bundled translation
    # lined up with `BibleBookCatalog.standard`.
    if book["id"] in CANONICAL_NAMES:
        book["name"] = CANONICAL_NAMES[book["id"]]
    return book


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit("usage: generate_translation_json.py <CODE> <usfm_dir> <output_dir>")
    code, usfm_dir, output_dir = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
    output_dir.mkdir(parents=True, exist_ok=True)
    written = 0
    for path in sorted(usfm_dir.glob("*.usfm")):
        book = parse_book(path.read_text(encoding="utf-8"))
        if book["id"] not in TESTAMENT:
            continue
        out = output_dir / f"{code}-{book['id']}.json"
        out.write_text(
            json.dumps(book, ensure_ascii=False, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        written += 1
    print(f"wrote {written} book files to {output_dir}")


if __name__ == "__main__":
    main()
