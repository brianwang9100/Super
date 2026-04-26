import Core
import Foundation

/// Built-in `ToolExecutor` that reports the current date and time.
///
/// `TimeNowTool` is the only real tool shipped in the MVP — it exists so the
/// end-to-end on-device tool path (registry → LLM advertisement → tool-call
/// dispatch → tool-result write-back) is exercised in production builds, not
/// only in tests. LLMs (Large Language Models) don't know wall-clock time on
/// their own, so questions like "what day is it?" or "what's the date in
/// Tokyo?" depend on this tool being available.
///
/// The clock and the default time zone are injected so tests can produce
/// deterministic output via `FixedClock` + a fixed `TimeZone`. The default
/// zone uses `.autoupdatingCurrent` so production picks up Settings changes
/// without a relaunch.
public struct TimeNowTool: ToolExecutor {
    /// Stable identifier used by both the LLM advertisement and the registry
    /// dispatch. Dotted form (`time.now`) namespaces the tool under a domain
    /// the way later tools (`todo.create`, `recipe.find`) will.
    public static let toolID = "time.now"

    /// Owning applet. The Chat applet ships this tool itself rather than
    /// registering it from a separate applet module — there's only one
    /// applet in the MVP, so the appletId is just an honest tag.
    public static let appletID = "chat"

    public let toolID: String = TimeNowTool.toolID

    private let clock: any Clock
    private let defaultTimeZone: TimeZone

    public init(
        clock: any Clock = SystemClock(),
        defaultTimeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.clock = clock
        self.defaultTimeZone = defaultTimeZone
    }

    /// Tool descriptor advertised to the LLM. Computed once at first access
    /// and reused — the value is constant.
    public static let descriptor: LLMTool = LLMTool(
        id: TimeNowTool.toolID,
        name: "time.now",
        description: """
        Returns the current date and time. Call this when the user asks \
        what time, day, or date it is, or when an answer depends on the \
        current moment (e.g. "is it past 5pm?", "how many days until \
        Friday?"). Pass `timezone` to request a specific IANA \
        (Internet Assigned Numbers Authority) zone like `Asia/Tokyo`; \
        omit it to use the user's current zone.
        """,
        category: .query,
        parameters: [
            LLMToolParameter(
                name: "timezone",
                type: .string,
                description: """
                Optional IANA timezone identifier (e.g. `Asia/Tokyo`, \
                `America/Los_Angeles`, `UTC`). Omit this parameter \
                unless the user explicitly named a specific city, \
                region, or timezone — otherwise the tool uses the \
                user's current timezone, which is almost always what \
                they want.
                """,
                isRequired: false
            ),
        ],
        appletId: TimeNowTool.appletID
    )

    /// Convenience that builds a `ToolRegistration` for a ready-to-use
    /// instance. Composition root calls this and hands the result to
    /// `ToolRegistry.register(_:)`.
    public static func registration(
        clock: any Clock = SystemClock(),
        defaultTimeZone: TimeZone = .autoupdatingCurrent
    ) -> ToolRegistration {
        ToolRegistration(
            tool: descriptor,
            execution: .local(TimeNowTool(clock: clock, defaultTimeZone: defaultTimeZone)),
            isEnabled: true
        )
    }

    public func execute(input: [String: JSONValue]) async throws -> ToolResult {
        let resolved = resolveTimeZone(from: input["timezone"])
        switch resolved {
        case .invalid(let raw):
            // Don't throw — return an `isError` result so the model can recover
            // ("I'll fall back to UTC") instead of seeing the whole turn fail.
            return ToolResult(
                toolID: TimeNowTool.toolID,
                content: "Unknown timezone identifier '\(raw)'. Pass a valid IANA name like 'Asia/Tokyo' or omit the parameter to use the user's current timezone.",
                isError: true
            )
        case .resolved(let zone):
            let instant = clock.now()
            let iso = TimeNowTool.iso8601String(for: instant, in: zone)
            let human = TimeNowTool.humanReadable(for: instant, in: zone)
            let content = "Current time: \(human) (\(iso), \(zone.identifier))"
            return ToolResult(
                toolID: TimeNowTool.toolID,
                content: content,
                isError: false
            )
        }
    }

    private func resolveTimeZone(from value: JSONValue?) -> ResolvedTimeZone {
        guard case .string(let raw) = value else {
            return .resolved(defaultTimeZone)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .resolved(defaultTimeZone)
        }
        if let zone = TimeZone(identifier: trimmed) {
            return .resolved(zone)
        }
        return .invalid(trimmed)
    }

    private enum ResolvedTimeZone {
        case resolved(TimeZone)
        case invalid(String)
    }

    private static func iso8601String(for date: Date, in zone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func humanReadable(for date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss a zzz"
        return formatter.string(from: date)
    }
}
