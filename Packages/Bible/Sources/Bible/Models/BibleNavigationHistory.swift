import Foundation

/// A bounded browser-style history of visited Bible chapters.
public struct BibleNavigationHistory: Codable, Sendable, Equatable {
    /// The maximum number of chapter visits retained in memory and storage.
    public static let capacity = 25

    /// Chapter visits in traversal order, including any forward branch.
    public private(set) var entries: [BiblePosition]
    /// The index of the chapter currently displayed by the reader.
    public private(set) var currentIndex: Int

    /// The chapter at the traversal cursor.
    public var current: BiblePosition {
        entries[currentIndex]
    }

    /// Whether the cursor can move to an earlier visit.
    public var canGoBack: Bool {
        currentIndex > entries.startIndex
    }

    /// Whether the cursor can move to a later visit.
    public var canGoForward: Bool {
        currentIndex < entries.index(before: entries.endIndex)
    }

    /// Creates a history whose sole current entry is `initialPosition`.
    public init(initialPosition: BiblePosition) {
        entries = [initialPosition]
        currentIndex = 0
    }

    /// Records a chapter visit, branching from the current cursor if needed.
    @discardableResult
    public mutating func visit(_ position: BiblePosition) -> Bool {
        guard position != current else { return false }

        entries.removeSubrange(entries.index(after: currentIndex)..<entries.endIndex)
        entries.append(position)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        currentIndex = entries.index(before: entries.endIndex)
        return true
    }

    /// Moves to the preceding visit when one exists.
    @discardableResult
    public mutating func goBack() -> Bool {
        guard canGoBack else { return false }
        currentIndex -= 1
        return true
    }

    /// Moves to the following visit when one exists.
    @discardableResult
    public mutating func goForward() -> Bool {
        guard canGoForward else { return false }
        currentIndex += 1
        return true
    }

    init?(entries: [BiblePosition], currentIndex: Int) {
        guard
            !entries.isEmpty,
            entries.count <= Self.capacity,
            entries.indices.contains(currentIndex)
        else {
            return nil
        }
        self.entries = entries
        self.currentIndex = currentIndex
    }

    /// Decodes history only when its entry and cursor invariants are valid.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decode([BiblePosition].self, forKey: .entries)
        let currentIndex = try container.decode(Int.self, forKey: .currentIndex)
        guard let history = Self(entries: entries, currentIndex: currentIndex) else {
            throw DecodingError.dataCorruptedError(
                forKey: .currentIndex,
                in: container,
                debugDescription: "History must contain 1...25 entries and a valid cursor."
            )
        }
        self = history
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case currentIndex
    }
}
