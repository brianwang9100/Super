#!/usr/bin/env python3
"""Convert World English Bible USFM into the Bible applet's per-book JSON.

Source text: the World English Bible (WEB), Protestant canon, public domain.
Download the USFM bundle from eBible.org before running:

    curl -sL -o engwebp.zip https://ebible.org/Scriptures/engwebp_usfm.zip
    unzip -q engwebp.zip -d engwebp_usfm

Usage:

    python3 generate_web_json.py <usfm_dir> <output_dir>

Emits one `WEB-<BOOKID>.json` per canonical book into <output_dir>. The JSON
schema is a discriminated union of paragraph types decoded by `BibleBook`:

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

PROSE_MARKERS = {"p", "m", "nb", "pi1", "mi", "li1", "ili"}
POETRY_MARKERS = {"q1", "q2"}
# Headings that follow their chapter: psalm titles (\d), speaker labels (\sp),
# and the five "BOOK N" dividers of Psalms (\ms1).
HEADING_MARKERS = {"d", "sp", "is1", "ms1"}

_FOOTNOTE = re.compile(r"\\f .+?\\f\*")
_CROSSREF = re.compile(r"\\x .+?\\x\*")
_WORD = re.compile(r"\\\+?w ([^\\|]*)(?:\|[^\\]*)?\\\+?w\*")
_CLOSING_MARKER = re.compile(r"\\\+?[a-z]+\d?\*")
_OPENING_MARKER = re.compile(r"\\\+?[a-z]+\d? ?")
_SPACES = re.compile(r"[ \t]+")
_LINE = re.compile(r"\\(\+?[a-z]+\d?) ?(.*)")


def clean(text: str) -> str:
    """Strip USFM inline markup, leaving plain reading text.

    Footnotes and cross-references are dropped entirely; word-level Strong's
    annotations and other character markers are unwrapped to their content.
    """
    text = _FOOTNOTE.sub("", text)
    text = _CROSSREF.sub("", text)
    text = _WORD.sub(r"\1", text)
    text = _CLOSING_MARKER.sub("", text)
    text = _OPENING_MARKER.sub("", text)
    return _SPACES.sub(" ", text).strip()


def parse_book(usfm: str) -> dict:
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
            chapter["paragraphs"].append({"type": "heading", "text": clean(rest)})
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
    return book


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit("usage: generate_web_json.py <usfm_dir> <output_dir>")
    usfm_dir, output_dir = Path(sys.argv[1]), Path(sys.argv[2])
    output_dir.mkdir(parents=True, exist_ok=True)
    written = 0
    for path in sorted(usfm_dir.glob("*.usfm")):
        book = parse_book(path.read_text(encoding="utf-8"))
        if book["id"] not in TESTAMENT:
            continue
        out = output_dir / f"WEB-{book['id']}.json"
        out.write_text(
            json.dumps(book, ensure_ascii=False, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        written += 1
    print(f"wrote {written} book files to {output_dir}")


if __name__ == "__main__":
    main()
