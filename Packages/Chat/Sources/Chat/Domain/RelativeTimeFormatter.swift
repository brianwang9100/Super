import Foundation

/// Pure relative-time bucketing for the Chats applet's row subtitles.
///
/// Mirrors the design's coarse-grained buckets ("just now", "12 min ago",
/// "Yesterday", "Last week", "3 mo ago") so a long history reads at a
/// glance. Pure for unit-testability and snapshot determinism — callers
/// inject the reference `now` and `calendar` rather than reading wall
/// clock state inside the formatter.
public enum RelativeTimeFormatter {
    /// Bucket `date` relative to `now` into a human-readable string.
    ///
    /// Negative deltas (a future `date`) collapse into the `just now`
    /// bucket so a clock skew or test-fixture drift never renders as
    /// "-5 min ago". Bucketing is pure-interval math — the same string
    /// falls out regardless of locale or calendar.
    public static func format(
        _ date: Date,
        now: Date
    ) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        let minutes = Int(elapsed / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr ago" }
        let days = hours / 24
        if days < 2 { return "Yesterday" }
        if days < 7 { return "\(days) days ago" }
        if days < 14 { return "Last week" }
        if days < 30 { return "\(days / 7) weeks ago" }
        return "\(days / 30) mo ago"
    }
}
