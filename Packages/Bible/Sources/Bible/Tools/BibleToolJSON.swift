import Core

/// Small `[String: JSONValue]` argument readers shared by the Bible tools
/// (`bible.read`, `bible.search`), so the two don't keep divergent copies of the
/// same parsing rules.
enum BibleToolJSON {
    /// The string value at `key`, or `nil` when absent or not a string.
    static func optionalString(_ input: [String: JSONValue], key: String) -> String? {
        guard case .string(let value) = input[key] else { return nil }
        return value
    }

    /// The integer value at `key`, accepting an integral double too (some
    /// providers serialize integers as doubles). `nil` when absent, non-numeric,
    /// non-finite, or fractional.
    static func optionalInt(_ input: [String: JSONValue], key: String) -> Int? {
        guard let raw = input[key] else { return nil }
        if case .int(let value) = raw { return value }
        if case .double(let value) = raw {
            // `Int(_:)` traps on NaN/±∞ — standard JSON can't carry those, but
            // guard before the cast so a non-finite value degrades to nil.
            guard value.isFinite else { return nil }
            let rounded = Int(value)
            return Double(rounded) == value ? rounded : nil
        }
        return nil
    }
}
