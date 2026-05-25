import Foundation
import Testing
@testable import Chat

/// Tests for `RelativeTimeFormatter.format(_:now:)` — bucket
/// boundaries and within-bucket pluralization. Matches the strings the
/// Chats applet design renders under each chat row.
@Suite("RelativeTimeFormatter")
struct RelativeTimeFormatterTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("under a minute renders 'just now'")
    func justNow() {
        let date = now.addingTimeInterval(-30)
        #expect(RelativeTimeFormatter.format(date, now: now) == "just now")
    }

    @Test("exactly one minute renders '1 min ago'")
    func oneMinute() {
        let date = now.addingTimeInterval(-60)
        #expect(RelativeTimeFormatter.format(date, now: now) == "1 min ago")
    }

    @Test("twelve minutes renders '12 min ago'")
    func twelveMinutes() {
        let date = now.addingTimeInterval(-12 * 60)
        #expect(RelativeTimeFormatter.format(date, now: now) == "12 min ago")
    }

    @Test("fifty-nine minutes stays in minutes bucket")
    func fiftyNineMinutes() {
        let date = now.addingTimeInterval(-59 * 60)
        #expect(RelativeTimeFormatter.format(date, now: now) == "59 min ago")
    }

    @Test("sixty minutes crosses into hours bucket")
    func sixtyMinutes() {
        let date = now.addingTimeInterval(-60 * 60)
        #expect(RelativeTimeFormatter.format(date, now: now) == "1 hr ago")
    }

    @Test("three hours renders '3 hr ago'")
    func threeHours() {
        let date = now.addingTimeInterval(-3 * 3600)
        #expect(RelativeTimeFormatter.format(date, now: now) == "3 hr ago")
    }

    @Test("twenty-three hours stays in hours bucket")
    func twentyThreeHours() {
        let date = now.addingTimeInterval(-23 * 3600)
        #expect(RelativeTimeFormatter.format(date, now: now) == "23 hr ago")
    }

    @Test("twenty-four hours renders 'Yesterday'")
    func twentyFourHours() {
        let date = now.addingTimeInterval(-24 * 3600)
        #expect(RelativeTimeFormatter.format(date, now: now) == "Yesterday")
    }

    @Test("forty-seven hours stays in Yesterday bucket")
    func fortySevenHours() {
        let date = now.addingTimeInterval(-47 * 3600)
        #expect(RelativeTimeFormatter.format(date, now: now) == "Yesterday")
    }

    @Test("forty-eight hours crosses into days bucket")
    func fortyEightHours() {
        let date = now.addingTimeInterval(-48 * 3600)
        #expect(RelativeTimeFormatter.format(date, now: now) == "2 days ago")
    }

    @Test("six days stays in days bucket")
    func sixDays() {
        let date = now.addingTimeInterval(-6 * 86_400)
        #expect(RelativeTimeFormatter.format(date, now: now) == "6 days ago")
    }

    @Test("seven days renders 'Last week'")
    func sevenDays() {
        let date = now.addingTimeInterval(-7 * 86_400)
        #expect(RelativeTimeFormatter.format(date, now: now) == "Last week")
    }

    @Test("thirteen days stays in Last week bucket")
    func thirteenDays() {
        let date = now.addingTimeInterval(-13 * 86_400)
        #expect(RelativeTimeFormatter.format(date, now: now) == "Last week")
    }

    @Test("fourteen days crosses into weeks bucket")
    func fourteenDays() {
        let date = now.addingTimeInterval(-14 * 86_400)
        #expect(RelativeTimeFormatter.format(date, now: now) == "2 weeks ago")
    }

    @Test("twenty-nine days stays in weeks bucket")
    func twentyNineDays() {
        let date = now.addingTimeInterval(-29 * 86_400)
        #expect(RelativeTimeFormatter.format(date, now: now) == "4 weeks ago")
    }

    @Test("thirty days crosses into months bucket")
    func thirtyDays() {
        let date = now.addingTimeInterval(-30 * 86_400)
        #expect(RelativeTimeFormatter.format(date, now: now) == "1 mo ago")
    }

    @Test("ninety days renders '3 mo ago'")
    func ninetyDays() {
        let date = now.addingTimeInterval(-90 * 86_400)
        #expect(RelativeTimeFormatter.format(date, now: now) == "3 mo ago")
    }

    @Test("future date still resolves to 'just now'")
    func futureDateIsJustNow() {
        // Clock skew or test fixture drift shouldn't render a negative count.
        let date = now.addingTimeInterval(60)
        #expect(RelativeTimeFormatter.format(date, now: now) == "just now")
    }
}
