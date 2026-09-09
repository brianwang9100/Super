import Core
import SwiftUI
import Testing
@testable import Bible

@Suite("BibleApplet conformance")
@MainActor
struct BibleAppletTests {
    private func makeApplet() -> BibleApplet {
        BibleApplet(viewModel: BibleScreenViewModel(textLoader: BundledBibleTextLoader()))
    }

    @Test("Apple narration keeps app lifecycle and microphone ownership without writable Bible storage")
    func narrationWithoutPersistenceSharesAudioLifecycle() async throws {
        let apple = FakeNarrationService()
        let viewModel = BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(), narration: NarrationController(service: apple)
        )
        let applet = BibleApplet(viewModel: viewModel)
        await viewModel.load()
        let audio = AudioActivity()
        audio.beginCapture()
        let setup = applet.configureNarration(
            keychain: UnusedAppletKeychain(), generator: UnusedAppletSpeech(),
            cache: try NarrationAudioCache.makeInMemory(), audioActivity: audio, appleService: apple,
            listSources: { Issue.record("Apple fallback must not query cloud credentials."); return [] }
        )
        #expect(setup == nil)
        #expect(viewModel.narration.settings == nil)
        let verses = [NarrationVerseUtterance(verseNumber: 1, text: "One")]
        viewModel.narration.start(utterances: verses)
        #expect(apple.startCallCount == 0)
        #expect(viewModel.narration.lastError == .preemptedByVoiceInput)
        audio.endCapture()
        viewModel.narration.start(utterances: verses)
        viewModel.narration._simulateEvent(.started(verseNumber: 1))
        // The permanent app observer invokes this hook even when BibleScreen is unmounted.
        audio.stopPlayback?()
        #expect(viewModel.narration.state == .idle)
        #expect(apple.stopCallCount == 1)
        viewModel.narration.stop()

        audio.beginCapture()
        let starts = apple.startCallCount
        viewModel.narration.start(utterances: verses)
        #expect(apple.startCallCount == starts)
        #expect(viewModel.narration.lastError == .preemptedByVoiceInput)
        audio.endCapture()
        viewModel.narration.start(utterances: verses)
        #expect(apple.startCallCount == starts + 1)
        #expect(viewModel.narration.lastError == nil)
        viewModel.narration.stop()
    }

    @Test("appletID is stable and matches the persisted shell value")
    func appletIDMatchesPlaceholderPersistence() {
        // Preserve existing saved backdrop IDs.
        #expect(BibleApplet.appletID == "bible")
        #expect(makeApplet().appletID == "bible")
    }

    @Test("display name renders as the sidebar label")
    func displayName() {
        #expect(makeApplet().displayName == "Bible")
    }

    @Test("icon view renders without throwing for the sidebar size")
    func iconViewCompiles() {
        _ = makeApplet().iconView(size: 20)
    }

    @Test("root view builds without throwing")
    func rootViewCompiles() {
        _ = makeApplet().rootView()
    }

    @Test("conforms to MiniApplet")
    func miniAppletConformance() {
        let applet: any MiniApplet = makeApplet()
        #expect(applet.appletID == "bible")
    }

    @Test("systemPrompt loads the bundled SystemPrompt.md")
    func systemPromptLoaded() {
        let body = makeApplet().systemPrompt
        #expect(!body.isEmpty)
        #expect(body.contains("Bible applet"))
    }

    /// Context requests previously triggered silent annotations; only explicit requests should annotate.
    @Test("systemPrompt steers annotate vs. answering in chat")
    func systemPromptSteersAnnotateBehavior() {
        let body = makeApplet().systemPrompt
        #expect(body.contains("bible.annotate"))
        #expect(body.lowercased().contains("explicitly asks to *annotate*"))
        #expect(body.contains("bible.note"))
    }

    @Test("compactSystemPrompt loads the bundled compact variant, not the full briefing")
    func compactSystemPromptLoaded() {
        let applet = makeApplet()
        let compact = applet.compactSystemPrompt
        // An empty compact resource silently falls back to the full briefing downstream.
        #expect(!compact.isEmpty)
        #expect(compact != applet.systemPrompt)
        #expect(compact.count < applet.systemPrompt.count / 2)
    }

    /// Describing tools omitted by CompactToolPolicy invites hallucinated calls.
    @Test("compactSystemPrompt omits dropped-tool guidance, keeps grounding tools")
    func compactSystemPromptMatchesCompactToolSet() {
        let compact = makeApplet().compactSystemPrompt
        #expect(!compact.contains("bible.annotate"))
        #expect(!compact.contains("bible.note"))
        #expect(compact.contains("bible.lookup"))
    }

    @Test("suggestedChatActions contributes non-empty Bible chat starters")
    func suggestedChatActions() {
        let actions = makeApplet().suggestedChatActions
        #expect(!actions.isEmpty)
        #expect(actions.allSatisfy { !$0.label.isEmpty && !$0.message.isEmpty })
        #expect(actions.contains { $0.label == "Today's reading" })
    }

    @Test("openRecord event with a verse-range reference navigates the view model")
    func openRecordEventDrivesViewModelNavigation() async throws {
        let viewModel = BibleScreenViewModel(textLoader: BundledBibleTextLoader())
        await viewModel.load()
        #expect(viewModel.position == BibleScreenViewModel.defaultPosition)

        let applet = BibleApplet(viewModel: viewModel)
        let bus = SuperEventBus()
        await applet.attach(to: bus)

        await withCheckedContinuation { continuation in
            applet._referenceInbox._onNextEvent {
                continuation.resume()
            }
            // Publish after arming the completion continuation to avoid missing the event.
            Task {
                let reference = BibleDeepLink(
                    bookId: "ROM", chapter: 8, verseStart: 28, verseEnd: 30
                ).recordReference
                await bus.publish(.openRecord(reference: reference))
            }
        }

        #expect(viewModel.position == BiblePosition(bookId: "ROM", chapterNumber: 8))
        #expect(viewModel.selectedVerses == [28, 29, 30])
    }

    @Test("openRecord event with a non-bible reference is ignored")
    func openRecordEventForOtherAppletIsIgnored() async throws {
        let viewModel = BibleScreenViewModel(textLoader: BundledBibleTextLoader())
        await viewModel.load()
        let original = viewModel.position

        let applet = BibleApplet(viewModel: viewModel)
        let bus = SuperEventBus()
        await applet.attach(to: bus)

        await withCheckedContinuation { continuation in
            applet._referenceInbox._onNextEvent {
                continuation.resume()
            }
            Task {
                let stray = RecordReference(
                    appletID: "todo", kind: "task", sourceID: "x",
                    displayLabel: "x", citation: "x", snapshot: ""
                )
                await bus.publish(.openRecord(reference: stray))
            }
        }

        #expect(viewModel.position == original)
    }

    private func makeSearchableApplet() throws -> BibleApplet {
        BibleApplet(
            viewModel: BibleScreenViewModel(textLoader: BundledBibleTextLoader()),
            textSearcher: try BundledBibleTextSearcher()
        )
    }

    @Test("registerLookupTool registers bible.lookup and action:'read' dispatches a passage read")
    func registerLookupToolReadDispatches() async throws {
        let registry = ToolRegistry()
        await (try makeSearchableApplet()).registerLookupTool(in: registry)

        let registrations = await registry.allRegistrations()
        let lookup = try #require(registrations.first { $0.tool.id == LookupBibleTool.toolID })
        #expect(lookup.isEnabled)
        #expect(lookup.tool.category == .query)

        let result = try await registry.execute(
            toolID: LookupBibleTool.toolID,
            input: [
                "action": .string("read"),
                "references": .array([
                    .object(["book": .string("John"), "chapter": .int(3), "startVerse": .int(16)]),
                ]),
            ]
        )
        #expect(result.isError == false)
        #expect(result.content.hasPrefix("John 3:16 (KJV)"))
    }

    @Test("action:'search' dispatches a content search through bible.lookup")
    func registerLookupToolSearchDispatches() async throws {
        let registry = ToolRegistry()
        await (try makeSearchableApplet()).registerLookupTool(in: registry)

        let result = try await registry.execute(
            toolID: LookupBibleTool.toolID,
            input: [
                "action": .string("search"),
                "query": .string("shepherd"),
                "book": .string("Psalms"),
            ]
        )
        #expect(result.isError == false)
        #expect(result.content.contains("23:1"))
        #expect(result.content.contains("shepherd"))
    }

    @Test("a book-scoped search resolves the catalog id against the real FTS rows")
    func registerLookupToolBookScopeNarrows() async throws {
        let registry = ToolRegistry()
        await (try makeSearchableApplet()).registerLookupTool(in: registry)

        // "shepherd" occurs in Psalms and John, so this proves the resolved book ID filters rows.
        let result = try await registry.execute(
            toolID: LookupBibleTool.toolID,
            input: [
                "action": .string("search"),
                "query": .string("shepherd"),
                "book": .string("Psalms"),
            ]
        )
        #expect(result.isError == false)
        #expect(result.content.contains("Psalms 23:1"))
        #expect(!result.content.contains("John"))
    }

    @Test("registerLookupTool is a no-op when the bundled text DB is unavailable")
    func registerLookupToolNoSearcherNoOp() async throws {
        let registry = ToolRegistry()
        // Without a searcher the combined lookup tool must not register.
        await makeApplet().registerLookupTool(in: registry)
        let registrations = await registry.allRegistrations()
        #expect(!registrations.contains { $0.tool.id == LookupBibleTool.toolID })
    }

    @Test("attach is idempotent — second call does not add another subscriber")
    func attachIsIdempotent() async throws {
        let viewModel = BibleScreenViewModel(textLoader: BundledBibleTextLoader())
        await viewModel.load()

        let applet = BibleApplet(viewModel: viewModel)
        let bus = SuperEventBus()
        // Several observers attach here; idempotence matters, not the absolute subscriber count.
        await applet.attach(to: bus)
        let firstCount = await bus.subscriberCount
        await applet.attach(to: bus)
        let secondCount = await bus.subscriberCount
        #expect(secondCount == firstCount)
    }
}

private struct UnusedAppletSpeech: SpeechGenerating {
    func generate(text: String, voice: OpenAISpeechVoice, apiKey: String) async throws -> Data {
        Issue.record("Persistence-free Apple narration must not request cloud speech.")
        return Data()
    }
}

private struct UnusedAppletKeychain: KeychainClient {
    func getString(ref: String) async throws -> String? {
        Issue.record("Apple fallback must not read cloud credentials.")
        return nil
    }
    func setString(_ value: String, ref: String) async throws {
        Issue.record("Apple fallback must not save cloud credentials.")
    }
    func delete(ref: String) async throws {
        Issue.record("Apple fallback must not remove cloud credentials.")
    }
}
