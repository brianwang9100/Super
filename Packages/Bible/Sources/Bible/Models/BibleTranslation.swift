/// Public-domain translations bundled in bible-text.sqlite. Raw values are the
/// persisted reading-position and text-database lookup codes.
public enum BibleTranslation: String, Sendable, Equatable, CaseIterable, Identifiable {
    /// King James Version, 2006 public-domain edition.
    case kjv = "KJV"
    /// World English Bible; the catalog's fixture reference.
    case web = "WEB"
    /// American Standard Version, 1901.
    case asv = "ASV"
    /// Berean Standard Bible — the modern-English option, released into the
    /// public domain under Creative Commons Zero on 2023-04-30.
    case bsb = "BSB"

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .web: "World English Bible"
        case .kjv: "King James Version"
        case .asv: "American Standard Version"
        case .bsb: "Berean Standard Bible"
        }
    }

    public static let defaultTranslation: BibleTranslation = .kjv

    /// Unknown stored codes fall back to the default translation.
    public static func named(_ code: String) -> BibleTranslation {
        BibleTranslation(rawValue: code) ?? .defaultTranslation
    }
}
