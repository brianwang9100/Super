import Core

enum BibleToolJSON {
    static func optionalString(_ input: [String: JSONValue], key: String) -> String? {
        guard case .string(let value) = input[key] else { return nil }
        return value
    }

    /// Accepts integral doubles because providers may encode integers that way.
    /// Returns nil for fractional, nonfinite, nonnumeric, or out-of-Int-range values.
    static func optionalInt(_ input: [String: JSONValue], key: String) -> Int? {
        guard let raw = input[key] else { return nil }
        if case .int(let value) = raw { return value }
        if case .double(let value) = raw {
            return Int(exactly: value)
        }
        return nil
    }
}
