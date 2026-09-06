#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Pins OpenAI setup and selected-company layouts across appearance and text sizes.
@Suite("OpenAI narration snapshots")
@MainActor
struct OpenAINarrationSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test(arguments: ["setup", "enabled", "disabled", "error"], ["light", "dark", "xxl"])
    func settings(state: String, appearance: String) async throws {
        let fixture = try await makeFixture(state: state)
        let view = NarrationSettingsPane(settings: fixture.settings, controller: fixture.controller, includesHeader: true)
            .superTheme(.make(appearance == "dark" ? .vellumDark : .vellumLight))
            .dynamicTypeSize(appearance == "xxl" ? .xxLarge : .large)
        verify(view, name: "settings_\(state)_\(appearance)", height: 874)
    }

    @Test(arguments: ["setup", "enabled"], ["light", "dark", "xxl"])
    func appleSetup(state: String, appearance: String) async throws {
        let fixture = try await makeFixture(state: state)
        let view = AppleNarrationSetupSheet(settings: fixture.settings)
            .superTheme(.make(appearance == "dark" ? .vellumDark : .vellumLight))
            .dynamicTypeSize(appearance == "xxl" ? .xxLarge : .large)
        verify(view, name: "apple_setup_\(state)_\(appearance)", height: 874)
    }

    @Test(arguments: ["setup", "enabled", "disabled", "error"], ["light", "dark", "xxl"])
    func openAISetup(state: String, appearance: String) async throws {
        let fixture = try await makeFixture(state: state)
        let view = OpenAINarrationSetupSheet(settings: fixture.settings, controller: fixture.controller)
            .superTheme(.make(appearance == "dark" ? .vellumDark : .vellumLight))
            .dynamicTypeSize(appearance == "xxl" ? .xxLarge : .large)
        verify(view, name: "openai_setup_\(state)_\(appearance)", height: 874)
    }

    @Test(arguments: ["light", "dark", "xxl"])
    func deletedBorrowedKey(appearance: String) async throws {
        let keychain = InMemoryKeychainClient()
        try await keychain.setString("snapshot-only", ref: "deleted-ref")
        let settings = NarrationSettingsController(
            repository: GRDBNarrationSettingsRepository(database: try BibleDatabase.makeInMemory()),
            keychain: keychain, listSources: { [] }, clock: FixedClock(), ids: DeterministicIDGenerator(), appleVoicesInstalled: { false }
        )
        try await settings.configure(credential: .init(id: "deleted-model", name: "Deleted model", keyRef: "deleted-ref"), enabled: true, useThisKey: true, expecting: 0)
        #expect(!settings.hasKey)
        let controller = NarrationController(service: FakeNarrationService(), settings: settings)
        let view = OpenAINarrationSetupSheet(settings: settings, controller: controller)
            .superTheme(.make(appearance == "dark" ? .vellumDark : .vellumLight))
            .dynamicTypeSize(appearance == "xxl" ? .xxLarge : .large)
        verify(view, name: "deleted_borrowed_key_\(appearance)", height: 874)
    }

    @Test(arguments: ["setup", "enabled"], ["light", "dark", "xxl"])
    func voicePicker(state: String, appearance: String) async throws {
        let fixture = try await makeFixture(state: state)
        if state == "enabled" { fixture.controller.voice = .marin }
        let view = NarrationVoicePicker(
            controller: fixture.controller,
            appleVoices: [.init(id: "apple-test", displayName: "Samantha — Enhanced")],
            onSelect: { _ in }, onInstallAppleVoices: {}
        )
        .superTheme(.make(appearance == "dark" ? .vellumDark : .vellumLight))
        .dynamicTypeSize(appearance == "xxl" ? .xxLarge : .large)
        if let failure = verifySnapshot(of: view, as: .image(layout: .fixed(width: 360, height: 520)),
                                        named: "voices_\(state)_\(appearance)",
                                        record: SnapshotEnvironment.isRecording ? .all : nil,
                                        testName: "voices_\(state)_\(appearance)") {
            Issue.record("\(failure)")
        }
    }

    @Test(arguments: ["preparing", "speaking", "error", "permission", "authentication"], ["light", "dark", "xxl"])
    func transport(state: String, appearance: String) async throws {
        let fixture = try await makeFixture(state: "enabled")
        let controller = fixture.controller
        controller.voice = .marin
        controller.start(utterances: [.init(verseNumber: 1, text: "In the beginning")])
        if state == "speaking" { controller._simulateEvent(.started(verseNumber: 1)) }
        if state == "error" { controller._simulateEvent(.failed(.speech(.invalidKey))) }
        if state == "permission" { controller._simulateEvent(.failed(.speech(.permissionDenied))) }
        if state == "authentication" { controller._simulateEvent(.failed(.speech(.authenticationFailed))) }
        let view = NarrationTransportSheet(controller: controller, citation: "Genesis 1:1 (WEB)", onStop: {}, onRestart: {}, onClose: {})
            .superTheme(.make(appearance == "dark" ? .vellumDark : .vellumLight))
            .dynamicTypeSize(appearance == "xxl" ? .xxLarge : .large)
        verify(view, name: "transport_\(state)_\(appearance)", height: 450)
    }

    private func makeFixture(state: String) async throws -> (settings: NarrationSettingsController, controller: NarrationController) {
        let settings = NarrationSettingsController(
            repository: GRDBNarrationSettingsRepository(database: try BibleDatabase.makeInMemory()),
            keychain: InMemoryKeychainClient(), listSources: { [] }, clock: FixedClock(), ids: DeterministicIDGenerator(), appleVoicesInstalled: { state != "setup" }
        )
        await settings.refreshAppleVoices()
        if state != "setup" { try await settings.saveDedicatedKey("snapshot-only", enabled: state != "disabled", expecting: 0) }
        if state == "error" { settings.errorMessage = "Could not save your key securely on this device. The connection was not updated." }
        let controller = NarrationController(service: FakeNarrationService(), cloudService: FakeNarrationService(), settings: settings)
        return (settings, controller)
    }

    private func verify(_ view: some View, name: String, height: CGFloat) {
        if let failure = verifySnapshot(of: view, as: .image(layout: .fixed(width: 402, height: height)), named: name,
                                        record: SnapshotEnvironment.isRecording ? .all : nil, testName: name) {
            Issue.record("\(failure)")
        }
    }
}
#endif
