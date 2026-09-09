import Observation

/// Buffers ordered messages until a main-actor consumer explicitly drains them.
@MainActor
@Observable
public final class OrderedInbox<Element: Sendable> {
    private var elements: [Element] = []

    /// Changes for every enqueue, even if a repeated value replaces a drained batch
    /// between view updates. Consumers observe this instead of array equality.
    public private(set) var revision: UInt64 = 0

    /// Creates an empty inbox.
    public init() {}

    /// Retains one message without coalescing it with earlier messages.
    public func enqueue(_ element: Element) {
        elements.append(element)
        revision &+= 1
    }

    /// Transfers the entire pending batch to the consumer in arrival order.
    public func drain() -> [Element] {
        defer { elements.removeAll() }
        return elements
    }

    /// Removes obsolete messages while preserving the order of surviving work.
    public func remove(where shouldRemove: (Element) -> Bool) {
        elements.removeAll(where: shouldRemove)
    }
}
