import Foundation

/// Displays a saved credential as synthetic bullets without putting the Keychain secret in the form.
struct NarrationKeyDraft {
    private static let placeholder = String(repeating: "•", count: 12)
    private(set) var isPlaceholder: Bool
    var value: String {
        didSet {
            if value != Self.placeholder { isPlaceholder = false }
        }
    }

    /// An untouched placeholder preserves the saved key; only a typed replacement may rotate it.
    var replacement: String {
        isPlaceholder ? "" : value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(hasSavedKey: Bool) {
        isPlaceholder = hasSavedKey
        value = hasSavedKey ? Self.placeholder : ""
    }

    mutating func beginEditing() {
        if isPlaceholder { clear() }
    }

    mutating func clear() {
        value = ""
        isPlaceholder = false
    }
}
