public enum BibleBookOrder: Sendable, Equatable, CaseIterable {
    /// Canonical order, grouped by testament.
    case traditional
    /// Display-name order in one flat list.
    case alphabetical
}
