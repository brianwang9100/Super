import Core
import Foundation

public struct TimeNowTool: ToolExecutor {
    public static let toolID = "time.now"

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
        appletId: TimeNowTool.appletID,
        displayName: "Current time",
        summary: "Reports the current date and time."
    )

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
            // Return a tool error so the model can recover without failing the whole turn.
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
