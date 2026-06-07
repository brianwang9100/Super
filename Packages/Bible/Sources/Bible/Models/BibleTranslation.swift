/// One of the bundled Bible translations.
///
/// All four are public-domain, Protestant-canon translations whose text ships in
/// the prebuilt `bible-text.sqlite`. The raw value is the storage code persisted
/// in `BibleReadingPositionRecord` and the `translation` key `DatabaseBibleTextLoader`
/// (and `bible.search`) resolve rows by.
public enum BibleTranslation: String, Sendable, Equatable, CaseIterable, Identifiable {
    /// King James Version (2006 public-domain edition) — the default, and the
    /// first row in the picker.
    case kjv = "KJV"
    /// World English Bible — the canon `BibleBookCatalog` is verified against.
    case web = "WEB"
    /// American Standard Version (1901).
    case asv = "ASV"
    /// Berean Standard Bible — the modern-English option, released into the
    /// public domain under Creative Commons Zero on 2023-04-30.
    case bsb = "BSB"

    public var id: String { rawValue }

    /// Full translation name shown as the picker row's subtitle.
    public var name: String {
        switch self {
        case .web: "World English Bible"
        case .kjv: "King James Version"
        case .asv: "American Standard Version"
        case .bsb: "Berean Standard Bible"
        }
    }

    /// The translation a fresh install opens in.
    public static let defaultTranslation: BibleTranslation = .kjv

    /// The translation for a stored code, falling back to the default when
    /// the code is unknown — a persisted row from a future build, say.
    public static func named(_ code: String) -> BibleTranslation {
        BibleTranslation(rawValue: code) ?? .defaultTranslation
    }
}
