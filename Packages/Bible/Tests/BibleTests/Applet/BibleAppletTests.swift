import Core
import SwiftUI
import Testing
@testable import Bible

/// Smoke checks for `BibleApplet` conformance. These don't render anything —
/// they verify the metadata the shell's `AppletRegistry` and sidebar rely on
/// so a future rename or accidental id flip surfaces here before the app
/// silently loses its persisted backdrop selection.
@Suite("BibleApplet conformance")
@MainActor
struct BibleAppletTests {
    /// Build the applet via its test seam — an in-memory view model with no
    /// persistence, so the suite never opens the real on-disk database.
    private func makeApplet() -> BibleApplet {
        BibleApplet(viewModel: BibleScreenViewModel(textLoader: BundledBibleTextLoader()))
    }

    @Test("appletID is stable and matches the persisted shell value")
    func appletIDMatchesPlaceholderPersistence() {
        // The shell reads `UserDefaults["shell.activeAppletID"]` at launch.
        // The previous `BiblePlaceholderApplet` wrote "bible" — the new
        // applet must keep the same id or every existing install loses
        // their persisted backdrop choice on upgrade.
        #expect(BibleApplet.appletID == "bible")
        #expect(makeApplet().appletID == "bible")
    }

    @Test("display name renders as the sidebar label")
    func displayName() {
        #expect(makeApplet().displayName == "Bible")
    }

    @Test("icon view renders without throwing for the sidebar size")
    func iconViewCompiles() {
        // Touching `body` would force a SwiftUI render pipeline; here we
        // just confirm the protocol contract returns a non-empty `AnyView`.
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
        // We assert structural shape, not literal wording, so the test
        // doesn't churn every time the prompt is edited.
        #expect(!body.isEmpty)
        #expect(body.contains("Bible applet"))
    }

    @Test("openRecord event with a verse-range reference navigates the view model")
    func openRecordEventDrivesViewModelNavigation() async throws {
        let viewModel = BibleScreenViewModel(textLoader: BundledBibleTextLoader())
        await viewModel.load()
        #expect(viewModel.position == BibleScreenViewModel.defaultPosition)

        let applet = BibleApplet(viewModel: viewModel)
        let bus = SuperEventBus()
        await applet.attach(to: bus)

        // Arm a continuation that fires *after* the inbox has processed
        // the next event — synchronisation by `await`, never `sleep`.
        await withCheckedContinuation { continuation in
            applet._referenceInbox._onNextEvent {
                continuation.resume()
            }
            // Publish on a child task so the continuation arming above
            // is already in place when the subscriber handles the event.
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

    @Test("registerReadTool registers bible.read and it dispatches a lookup")
    func registerReadToolDispatches() async throws {
        let registry = ToolRegistry()
        await makeApplet().registerReadTool(in: registry)

        let registrations = await registry.allRegistrations()
        let read = try #require(registrations.first { $0.tool.id == ReadBibleTool.toolID })
        #expect(read.isEnabled)
        #expect(read.tool.category == .query)

        // Dispatch through the registry against the real bundled KJV text.
        let result = try await registry.execute(
            toolID: ReadBibleTool.toolID,
            input: ["book": .string("John"), "chapter": .int(3), "startVerse": .int(16)]
        )
        #expect(result.isError == false)
        #expect(result.content.hasPrefix("John 3:16 (KJV)"))
    }

    @Test("registerSearchTool registers bible.search and it dispatches a search")
    func registerSearchToolDispatches() async throws {
        // Build the applet with a real searcher over the bundled FTS index.
        let applet = BibleApplet(
            viewModel: BibleScreenViewModel(textLoader: BundledBibleTextLoader()),
            textSearcher: try BundledBibleTextSearcher()
        )
        let registry = ToolRegistry()
        await applet.registerSearchTool(in: registry)

        let registrations = await registry.allRegistrations()
        let search = try #require(registrations.first { $0.tool.id == SearchBibleTool.toolID })
        #expect(search.isEnabled)
        #expect(search.tool.category == .query)

        // Dispatch through the registry against the real bundled KJV text.
        let result = try await registry.execute(
            toolID: SearchBibleTool.toolID,
            input: ["query": .string("shepherd"), "book": .string("Psalms")]
        )
        #expect(result.isError == false)
        #expect(result.content.contains("23:1"))
        #expect(result.content.contains("shepherd"))
    }

    @Test("a book-scoped search resolves the catalog id against the real FTS rows")
    func registerSearchToolBookScopeNarrows() async throws {
        let applet = BibleApplet(
            viewModel: BibleScreenViewModel(textLoader: BundledBibleTextLoader()),
            textSearcher: try BundledBibleTextSearcher()
        )
        let registry = ToolRegistry()
        await applet.registerSearchTool(in: registry)

        // "shepherd" appears in both Psalms (23:1) and John (10:11); scoping to
        // Psalms must include the Psalm 23 hit and exclude the John one — proof
        // the catalog-resolved book id ("PSA") actually filters the bundled rows.
        let result = try await registry.execute(
            toolID: SearchBibleTool.toolID,
            input: ["query": .string("shepherd"), "book": .string("Psalms")]
        )
        #expect(result.isError == false)
        #expect(result.content.contains("Psalms 23:1"))
        #expect(!result.content.contains("John"))
    }

    @Test("attach is idempotent — second call does not add another subscriber")
    func attachIsIdempotent() async throws {
        let viewModel = BibleScreenViewModel(textLoader: BundledBibleTextLoader())
        await viewModel.load()

        let applet = BibleApplet(viewModel: viewModel)
        let bus = SuperEventBus()
        // PR4 onwards `BibleApplet.attach(to:)` wires both the
        // `BibleReferenceInbox` (inbound `openRecord`) and the
        // `BibleScreenViewModel` (inbound `bibleAnnotateCompleted`),
        // so the absolute subscriber count after the first attach is
        // implementation-defined. The load-bearing invariant is that
        // the *second* attach doesn't change it.
        await applet.attach(to: bus)
        let firstCount = await bus.subscriberCount
        await applet.attach(to: bus)
        let secondCount = await bus.subscriberCount
        #expect(secondCount == firstCount)
    }
}
