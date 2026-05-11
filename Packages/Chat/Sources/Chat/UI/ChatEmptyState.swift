import Core
import Foundation
import SwiftUI

/// Centered greeting shown when a conversation has no messages.
///
/// The greeting text varies by hour-of-day (`How can I help you this
/// morning?` / `…afternoon?` / `…evening?` / `…tonight?`). The clock is
/// injected so snapshot tests are deterministic.
///
/// Mirrors `EmptyState` in `.design-tmp/chat/project/src/chat-view.jsx`.
public struct ChatEmptyState: View {
    public let greeting: String

    public init(greeting: String) {
        self.greeting = greeting
    }

    /// Convenience that derives the greeting from `clock.now()` against the
    /// current calendar. The view itself stays pure; the time-of-day logic
    /// lives in `Self.greeting(for:calendar:)` so both the view and the
    /// composition root call into the same function.
    public init(clock: any Clock = SystemClock(), calendar: Calendar = .current) {
        self.greeting = Self.greeting(for: clock.now(), calendar: calendar)
    }

    @Environment(\.superTheme) private var theme

    public var body: some View {
        VStack(spacing: 0) {
            SparkIcon(size: 36)
                .foregroundStyle(theme.accent)
                .opacity(0.8)
                .padding(.bottom, 18)
            Text(greeting)
                .font(.custom("Instrument Serif", size: 26, relativeTo: .title))
                .tracking(-0.26)
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.ink)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
    }

    /// Map an hour-of-day to one of the four greeting strings. Pure so
    /// snapshot tests can drive every branch with a `FixedClock`. Marked
    /// `nonisolated` because the SwiftUI `View` conformance otherwise
    /// inherits `@MainActor`, which forced every test caller into an
    /// actor-isolated context (Swift 6 stricter toolchains rejected this).
    nonisolated public static func greeting(for date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case ..<5:    return "How can I help you tonight?"
        case 5..<12:  return "How can I help you this morning?"
        case 12..<17: return "How can I help you this afternoon?"
        case 17..<21: return "How can I help you this evening?"
        default:      return "How can I help you tonight?"
        }
    }
}
