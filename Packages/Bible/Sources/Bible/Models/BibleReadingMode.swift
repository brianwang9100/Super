public enum BibleReadingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case book, compare, study
    public var id: String { rawValue }

    var next: Self {
        switch self {
        case .book: .compare
        case .compare: .study
        case .study: .book
        }
    }
}
