import Core
import Foundation
import Testing
@testable import Chat

/// Tests for `TimeNowTool` — descriptor shape, deterministic output via
/// `FixedClock` + fixed `TimeZone`, IANA (Internet Assigned Numbers
/// Authority) timezone override, invalid-zone soft failure, and missing /
/// non-string parameter handling.
@Suite("TimeNowTool")
struct TimeNowToolTests {
    private static let fixedInstant = Date(timeIntervalSince1970: 1_750_000_000)
    private static let utc = TimeZone(identifier: "UTC")!
    private static let pacific = TimeZone(identifier: "America/Los_Angeles")!
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    @Test
    func descriptorAdvertisesIdCategoryAndOptionalTimezone() {
        let tool = TimeNowTool.descriptor

        #expect(tool.id == "time.now")
        #expect(tool.name == "time.now")
        #expect(tool.category == .query)
        #expect(tool.appletId == TimeNowTool.appletID)
        #expect(tool.parameters.count == 1)

        let timezone = tool.parameters[0]
        #expect(timezone.name == "timezone")
        #expect(timezone.type == .string)
        #expect(timezone.isRequired == false)
    }

    @Test
    func registrationReturnsEnabledLocalRegistration() {
        let registration = TimeNowTool.registration()
        #expect(registration.tool.id == TimeNowTool.toolID)
        #expect(registration.isEnabled == true)
        guard case .local = registration.execution else {
            Issue.record("expected .local execution")
            return
        }
    }

    @Test
    func defaultsToInjectedTimeZoneWhenParameterMissing() async throws {
        let executor = TimeNowTool(
            clock: FixedClock(Self.fixedInstant),
            defaultTimeZone: Self.pacific
        )

        let result = try await executor.execute(input: [:])

        #expect(result.isError == false)
        #expect(result.toolID == TimeNowTool.toolID)
        #expect(result.content.contains("America/Los_Angeles"))
        // 2025-06-15 08:06:40 PDT — UTC-7 on this date
        #expect(result.content.contains("2025-06-15T08:06:40-07:00"))
        #expect(result.content.contains("Sunday"))
    }

    @Test
    func explicitIANATimeZoneOverridesDefault() async throws {
        let executor = TimeNowTool(
            clock: FixedClock(Self.fixedInstant),
            defaultTimeZone: Self.pacific
        )

        let result = try await executor.execute(input: ["timezone": .string("Asia/Tokyo")])

        #expect(result.isError == false)
        #expect(result.content.contains("Asia/Tokyo"))
        // Same instant as the Pacific test above, expressed in Tokyo (+09:00):
        // 2025-06-16 00:06:40 JST.
        #expect(result.content.contains("2025-06-16T00:06:40+09:00"))
        #expect(result.content.contains("Monday"))
    }

    @Test
    func utcShortcutResolves() async throws {
        let executor = TimeNowTool(
            clock: FixedClock(Self.fixedInstant),
            defaultTimeZone: Self.pacific
        )

        let result = try await executor.execute(input: ["timezone": .string("UTC")])

        #expect(result.isError == false)
        // Foundation canonicalizes "UTC" → "GMT" on the resolved `TimeZone`'s
        // identifier; either label is acceptable to the LLM.
        let zoneLabel = TimeZone(identifier: "UTC")?.identifier ?? "UTC"
        #expect(result.content.contains(zoneLabel))
        #expect(result.content.contains("2025-06-15T15:06:40"))
    }

    @Test
    func invalidTimeZoneIdentifierReturnsIsErrorWithoutThrowing() async throws {
        let executor = TimeNowTool(
            clock: FixedClock(Self.fixedInstant),
            defaultTimeZone: Self.utc
        )

        let result = try await executor.execute(input: ["timezone": .string("Mars/Olympus_Mons")])

        #expect(result.isError == true)
        #expect(result.toolID == TimeNowTool.toolID)
        #expect(result.content.contains("Mars/Olympus_Mons"))
        #expect(result.content.contains("IANA"))
    }

    @Test
    func nonStringTimeZoneParameterFallsBackToDefault() async throws {
        let executor = TimeNowTool(
            clock: FixedClock(Self.fixedInstant),
            defaultTimeZone: Self.utc
        )

        let result = try await executor.execute(input: ["timezone": .int(42)])

        #expect(result.isError == false)
        let zoneLabel = TimeZone(identifier: "UTC")?.identifier ?? "UTC"
        #expect(result.content.contains(zoneLabel))
    }

    @Test
    func emptyStringTimeZoneParameterFallsBackToDefault() async throws {
        let executor = TimeNowTool(
            clock: FixedClock(Self.fixedInstant),
            defaultTimeZone: Self.tokyo
        )

        let result = try await executor.execute(input: ["timezone": .string("   ")])

        #expect(result.isError == false)
        #expect(result.content.contains("Asia/Tokyo"))
    }

    @Test
    func clockAdvanceChangesReportedTime() async throws {
        let clock = FixedClock(Self.fixedInstant)
        let executor = TimeNowTool(clock: clock, defaultTimeZone: Self.utc)

        let first = try await executor.execute(input: [:])
        clock.advance(by: 3600)
        let second = try await executor.execute(input: [:])

        #expect(first.content.contains("2025-06-15T15:06:40"))
        #expect(second.content.contains("2025-06-15T16:06:40"))
    }
}
