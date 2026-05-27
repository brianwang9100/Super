import Foundation

/// One canonical Bible book — display name, three-letter identifier,
/// chapter count, and any spelling variants the parser should accept as
/// equivalent. Used by ``BibleBookIndex`` for verse-reference detection
/// in Chat and by deep-link parsing in the shell.
///
/// This is plain reference data, no behaviour. The Bible applet keeps
/// its own richer `BibleBookSummary` (which also tracks testament); a
/// Bible-side consistency test asserts these two stay in lockstep so
/// the canon never drifts between the parser's view and the reader's
/// view.
public struct BibleBookEntry: Sendable, Equatable {
    /// USFM-style three-letter code, e.g. `"GEN"`, `"1CO"`, `"SNG"`. Matches
    /// the IDs used by the Bible applet's bundled text JSON files and by
    /// `RecordReference.sourceID` for verse-range references.
    public let id: String
    /// Full display name in the form a human would write (and the form
    /// the Bible system prompt instructs the LLM to use). For instance,
    /// `"1 Corinthians"`, `"Song of Solomon"`, `"Psalms"`.
    public let name: String
    /// Highest chapter number the book contains — used by the parser to
    /// reject obviously-bad citations like `Genesis 51:1` (Genesis has 50).
    public let chapterCount: Int
    /// Additional spellings the parser should accept as this same book.
    /// Kept tight: only the variants the LLM realistically produces given
    /// the system prompt's "full book name" guidance. Today: `"Psalm"`
    /// (singular) for `PSA`, and `"Song of Songs"` for `SNG`.
    public let aliases: [String]

    public init(id: String, name: String, chapterCount: Int, aliases: [String] = []) {
        self.id = id
        self.name = name
        self.chapterCount = chapterCount
        self.aliases = aliases
    }
}

/// The 66 Protestant-canon books as parse-time reference data. Lives in
/// Core (not Bible) because the verse-reference linkifier in Chat and the
/// shell's `onOpenURL` deep-link handler both need it, and applets
/// cannot import each other.
///
/// All look-ups are case-sensitive against the canonical display name and
/// the small set of aliases each entry declares. The LLM is steered toward
/// these spellings by the Bible system prompt; matching loosely here would
/// let user typos and accidental prose ("Section 1:2") become tap targets
/// the user didn't intend.
public enum BibleBookIndex {
    /// Books in canonical reading order — Genesis first, Revelation last.
    /// Stored as `let` (not `var`) so accidental mutation is a compile error.
    public static let canonical: [BibleBookEntry] = [
        // Old Testament
        BibleBookEntry(id: "GEN", name: "Genesis", chapterCount: 50),
        BibleBookEntry(id: "EXO", name: "Exodus", chapterCount: 40),
        BibleBookEntry(id: "LEV", name: "Leviticus", chapterCount: 27),
        BibleBookEntry(id: "NUM", name: "Numbers", chapterCount: 36),
        BibleBookEntry(id: "DEU", name: "Deuteronomy", chapterCount: 34),
        BibleBookEntry(id: "JOS", name: "Joshua", chapterCount: 24),
        BibleBookEntry(id: "JDG", name: "Judges", chapterCount: 21),
        BibleBookEntry(id: "RUT", name: "Ruth", chapterCount: 4),
        BibleBookEntry(id: "1SA", name: "1 Samuel", chapterCount: 31),
        BibleBookEntry(id: "2SA", name: "2 Samuel", chapterCount: 24),
        BibleBookEntry(id: "1KI", name: "1 Kings", chapterCount: 22),
        BibleBookEntry(id: "2KI", name: "2 Kings", chapterCount: 25),
        BibleBookEntry(id: "1CH", name: "1 Chronicles", chapterCount: 29),
        BibleBookEntry(id: "2CH", name: "2 Chronicles", chapterCount: 36),
        BibleBookEntry(id: "EZR", name: "Ezra", chapterCount: 10),
        BibleBookEntry(id: "NEH", name: "Nehemiah", chapterCount: 13),
        BibleBookEntry(id: "EST", name: "Esther", chapterCount: 10),
        BibleBookEntry(id: "JOB", name: "Job", chapterCount: 42),
        BibleBookEntry(id: "PSA", name: "Psalms", chapterCount: 150, aliases: ["Psalm"]),
        BibleBookEntry(id: "PRO", name: "Proverbs", chapterCount: 31),
        BibleBookEntry(id: "ECC", name: "Ecclesiastes", chapterCount: 12),
        BibleBookEntry(id: "SNG", name: "Song of Solomon", chapterCount: 8, aliases: ["Song of Songs"]),
        BibleBookEntry(id: "ISA", name: "Isaiah", chapterCount: 66),
        BibleBookEntry(id: "JER", name: "Jeremiah", chapterCount: 52),
        BibleBookEntry(id: "LAM", name: "Lamentations", chapterCount: 5),
        BibleBookEntry(id: "EZK", name: "Ezekiel", chapterCount: 48),
        BibleBookEntry(id: "DAN", name: "Daniel", chapterCount: 12),
        BibleBookEntry(id: "HOS", name: "Hosea", chapterCount: 14),
        BibleBookEntry(id: "JOL", name: "Joel", chapterCount: 3),
        BibleBookEntry(id: "AMO", name: "Amos", chapterCount: 9),
        BibleBookEntry(id: "OBA", name: "Obadiah", chapterCount: 1),
        BibleBookEntry(id: "JON", name: "Jonah", chapterCount: 4),
        BibleBookEntry(id: "MIC", name: "Micah", chapterCount: 7),
        BibleBookEntry(id: "NAM", name: "Nahum", chapterCount: 3),
        BibleBookEntry(id: "HAB", name: "Habakkuk", chapterCount: 3),
        BibleBookEntry(id: "ZEP", name: "Zephaniah", chapterCount: 3),
        BibleBookEntry(id: "HAG", name: "Haggai", chapterCount: 2),
        BibleBookEntry(id: "ZEC", name: "Zechariah", chapterCount: 14),
        BibleBookEntry(id: "MAL", name: "Malachi", chapterCount: 4),
        // New Testament
        BibleBookEntry(id: "MAT", name: "Matthew", chapterCount: 28),
        BibleBookEntry(id: "MRK", name: "Mark", chapterCount: 16),
        BibleBookEntry(id: "LUK", name: "Luke", chapterCount: 24),
        BibleBookEntry(id: "JHN", name: "John", chapterCount: 21),
        BibleBookEntry(id: "ACT", name: "Acts", chapterCount: 28),
        BibleBookEntry(id: "ROM", name: "Romans", chapterCount: 16),
        BibleBookEntry(id: "1CO", name: "1 Corinthians", chapterCount: 16),
        BibleBookEntry(id: "2CO", name: "2 Corinthians", chapterCount: 13),
        BibleBookEntry(id: "GAL", name: "Galatians", chapterCount: 6),
        BibleBookEntry(id: "EPH", name: "Ephesians", chapterCount: 6),
        BibleBookEntry(id: "PHP", name: "Philippians", chapterCount: 4),
        BibleBookEntry(id: "COL", name: "Colossians", chapterCount: 4),
        BibleBookEntry(id: "1TH", name: "1 Thessalonians", chapterCount: 5),
        BibleBookEntry(id: "2TH", name: "2 Thessalonians", chapterCount: 3),
        BibleBookEntry(id: "1TI", name: "1 Timothy", chapterCount: 6),
        BibleBookEntry(id: "2TI", name: "2 Timothy", chapterCount: 4),
        BibleBookEntry(id: "TIT", name: "Titus", chapterCount: 3),
        BibleBookEntry(id: "PHM", name: "Philemon", chapterCount: 1),
        BibleBookEntry(id: "HEB", name: "Hebrews", chapterCount: 13),
        BibleBookEntry(id: "JAS", name: "James", chapterCount: 5),
        BibleBookEntry(id: "1PE", name: "1 Peter", chapterCount: 5),
        BibleBookEntry(id: "2PE", name: "2 Peter", chapterCount: 3),
        BibleBookEntry(id: "1JN", name: "1 John", chapterCount: 5),
        BibleBookEntry(id: "2JN", name: "2 John", chapterCount: 1),
        BibleBookEntry(id: "3JN", name: "3 John", chapterCount: 1),
        BibleBookEntry(id: "JUD", name: "Jude", chapterCount: 1),
        BibleBookEntry(id: "REV", name: "Revelation", chapterCount: 22),
    ]

    /// Every distinct spelling the index will accept, sorted by descending
    /// length so a parser that walks `spellings` in order matches the
    /// longest candidate first. Essential for multi-word books — without
    /// this, `John 3:16` could be matched as a prefix of `1 John 3:16` if
    /// the shorter name appears earlier in the list.
    public static let spellingsLongestFirst: [(spelling: String, entry: BibleBookEntry)] = {
        var pairs: [(String, BibleBookEntry)] = []
        for entry in canonical {
            pairs.append((entry.name, entry))
            for alias in entry.aliases {
                pairs.append((alias, entry))
            }
        }
        return pairs
            .sorted { $0.0.count > $1.0.count }
            .map { (spelling: $0.0, entry: $0.1) }
    }()

    /// Look up an entry by exact canonical name or alias. Case-sensitive —
    /// the LLM is instructed to emit canonical capitalisation, and a loose
    /// match would let `genesis 1:1` slip through where the LLM is being
    /// stylistically lowercase.
    public static func lookup(_ name: String) -> BibleBookEntry? {
        spellingsLongestFirst.first { $0.spelling == name }?.entry
    }

    /// Look up an entry by three-letter ID, e.g. `"GEN"` → Genesis.
    /// Used by deep-link URL parsing and by Bible-side hand-off back into
    /// the reader.
    public static func entry(id: String) -> BibleBookEntry? {
        canonical.first { $0.id == id }
    }
}
