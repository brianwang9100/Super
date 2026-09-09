import Foundation

public enum RelativeTimeFormatter {
    /// Future dates collapse into "just now" rather than showing a negative interval.
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
