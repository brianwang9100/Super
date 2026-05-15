/// How the book picker sorts and groups its list.
public enum BibleBookOrder: Sendable, Equatable, CaseIterable {
    /// Genesis → Revelation, split into Old and New Testament sections.
    case traditional
    /// A → Z by display name, in a single flat list.
    case alphabetical
}
