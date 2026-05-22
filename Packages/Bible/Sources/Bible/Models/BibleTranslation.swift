/// One of the bundled Bible translations.
///
/// All four are public-domain, Protestant-canon translations whose text
/// ships in the package as `<rawValue>-<bookID>.json` resources. The raw
/// value is the storage code persisted in `BibleReadingPositionRecord` and
/// the lookup key `BundledBibleTextLoader` resolves resources by.
public enum BibleTranslation: String, Sendable, Equatable, CaseIterable, Identifiable {
    /// World English Bible — the default, and the canon `BibleBookCatalog`
    /// is verified against.
    case web = "WEB"
    /// King James Version (2006 public-domain edition).
    case kjv = "KJV"
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
    public static let defaultTranslation: BibleTranslation = .web

    /// The translation for a stored code, falling back to the default when
    /// the code is unknown — a persisted row from a future build, say.
    public static func named(_ code: String) -> BibleTranslation {
        BibleTranslation(rawValue: code) ?? .defaultTranslation
    }
}
