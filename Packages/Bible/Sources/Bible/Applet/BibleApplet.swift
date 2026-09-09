import Core
import Foundation
import GRDBQuery
import SwiftUI
import os

private let bibleAppletLog = Logger(subsystem: "com.brianwang.Super", category: "bible-applet")

/// Retains one reader view model across root-view rebuilds. User-data failures
/// disable persistence and dependent tools while leaving bundled text available.
public struct BibleApplet: MiniApplet {
    public static let appletID: String = "bible"
    public var appletID: String { Self.appletID }
    public var displayName: String { "Bible" }
    public static let accentColor: Color = Color(red: 0.52, green: 0.32, blue: 0.55)
    public var accentColor: Color { Self.accentColor }
    public var systemPrompt: String { AppletSystemPrompt.load(from: .module) }
    /// Omits guidance for tools excluded by CompactToolPolicy to avoid hallucinated calls.
    public var compactSystemPrompt: String {
        AppletSystemPrompt.load(from: .module, resource: "SystemPrompt.compact")
    }

    public var suggestedChatActions: [SuggestedChatAction] {
        [
            SuggestedChatAction(label: "Explain a verse", message: "Explain a Bible verse to me."),
            SuggestedChatAction(label: "Today's reading", message: "What should I read in the Bible today?"),
            SuggestedChatAction(label: "Write a prayer", message: "Write a short prayer for me."),
        ]
    }

    private let viewModel: BibleScreenViewModel

    // Held for the app session; attach during bootstrap to receive links while the reader is unmounted.
    private let referenceInbox: BibleReferenceInbox

    // Nil storage context makes decoration queries return empty results.
    private let databaseContext: DatabaseContext?

    // Keep the writable database inside Bible; the bulk runner shares its ledger.
    private let database: BibleDatabase?

    private let annotationRepository: (any BibleAnnotationRepository)?

    private let noteRepository: (any BibleNoteRepository)?

    // Share the reader's queue so tool writes update its queries.
    private let highlightRepository: (any BibleHighlightRepository)?

    // Nil user storage still permits lookup with the default translation.
    private let readingPositionRepository: (any BibleReadingPositionRepository)?

    private let textSearcher: (any BibleTextSearching)?

    /// Opens user storage synchronously under Application Support; bundled text is independent.
    @MainActor
    public init(hapticsEngine: any HapticsEngine = NoOpHapticsEngine()) {
        let database = BibleApplet.openDatabase()
        self.database = database
        self.databaseContext = database.map { db in
            DatabaseContext.readOnly { db.queue }
        }
        self.annotationRepository = database.map { GRDBBibleAnnotationRepository(database: $0) }
        let noteRepository = database.map { GRDBBibleNoteRepository(database: $0) }
        self.noteRepository = noteRepository
        let readingPositionRepository = database.map { GRDBBibleReadingPositionRepository(database: $0) }
        self.readingPositionRepository = readingPositionRepository
        let highlightRepository = database.map { GRDBBibleHighlightRepository(database: $0) }
        self.highlightRepository = highlightRepository
        // Share the bundled read-only database between reading and search. A missing or corrupt
        // resource yields unavailable text and disables lookup without crashing the reader.
        let textDatabase = try? BibleTextDatabase.openBundled()
        self.textSearcher = textDatabase.map(BundledBibleTextSearcher.init(database:))
        // The shell installs shared AudioActivity arbitration through configureNarration.
        let viewModel = BibleScreenViewModel(
            textLoader: DatabaseBibleTextLoader(database: textDatabase),
            positionRepository: readingPositionRepository,
            highlightRepository: highlightRepository,
            noteRepository: noteRepository,
            bookmarkRepository: database.map { GRDBBibleBookmarkRepository(database: $0) },
            hapticsEngine: hapticsEngine
        )
        self.viewModel = viewModel
        self.referenceInbox = BibleReferenceInbox(viewModel: viewModel)
    }

    /// Injects test storage without opening the on-disk database. A nil context yields empty decorations.
    @MainActor
    init(
        viewModel: BibleScreenViewModel,
        databaseContext: DatabaseContext? = nil,
        annotationRepository: (any BibleAnnotationRepository)? = nil,
        noteRepository: (any BibleNoteRepository)? = nil,
        highlightRepository: (any BibleHighlightRepository)? = nil,
        readingPositionRepository: (any BibleReadingPositionRepository)? = nil,
        textSearcher: (any BibleTextSearching)? = nil
    ) {
        self.viewModel = viewModel
        self.referenceInbox = BibleReferenceInbox(viewModel: viewModel)
        self.database = nil
        self.databaseContext = databaseContext
        self.annotationRepository = annotationRepository
        self.noteRepository = noteRepository
        self.highlightRepository = highlightRepository
        self.readingPositionRepository = readingPositionRepository
        self.textSearcher = textSearcher
    }

    /// Configures optional cloud narration without coupling Bible to the Chat applet.
    @MainActor
    public func configureNarration(
        keychain: any KeychainClient,
        generator: any SpeechGenerating,
        cache: any NarrationAudioCaching,
        audioActivity: AudioActivity,
        appleService: any NarrationService = AVSpeechSynthesizerNarrationService(),
        listSources: @escaping @Sendable () async -> [ProviderAudioCredential]
    ) -> (setup: ProviderAudioSetup, contribution: AppletSettingsContribution)? {
        guard let database else {
            // Reading and Apple speech remain available without writable storage.
            // They still share the app-lifetime stop hook and microphone ownership.
            viewModel.installNarration(NarrationController(service: appleService, audioActivity: audioActivity))
            return nil
        }
        let settings = NarrationSettingsController(
            repository: GRDBNarrationSettingsRepository(database: database), keychain: keychain, listSources: listSources
        )
        let cloud = OpenAINarrationService(generator: generator, player: NarrationAudioPlayer(), cache: cache,
                                           prefetchVerseCount: { settings.record.prefetchVerseCount }) {
            try await settings.apiKey()
        }
        let controller = NarrationController(
            service: appleService, cloudService: cloud,
            settings: settings, cache: cache, audioActivity: audioActivity
        )
        viewModel.installNarration(controller)
        return (settings.providerSetup, AppletSettingsContribution(
            id: "bible.narration", label: "Narration", icon: AnyView(Image(systemName: "speaker.wave.2")),
            value: { settings.openAIAvailable ? "Apple + OpenAI" : "Apple" },
            destination: { AnyView(NarrationSettingsPane(settings: settings, controller: controller)) }
        ))
    }

    /// No-op when user storage failed to open. Production must supply an active-model
    /// stamp provider so saved annotations carry model provenance.
    public func registerAnnotationTool(
        in registry: ToolRegistry,
        stampProvider: any BibleAnnotationStampProvider,
        clock: any Clock = SystemClock(),
        ids: any IDGenerator = UUIDGenerator()
    ) async {
        guard let annotationRepository else { return }
        await registry.register(
            AnnotateBibleTool.registration(
                repository: annotationRepository,
                stampProvider: stampProvider,
                clock: clock,
                ids: ids
            )
        )
    }

    /// No-op when user storage failed to open.
    public func registerNoteTool(
        in registry: ToolRegistry,
        clock: any Clock = SystemClock(),
        ids: any IDGenerator = UUIDGenerator(),
        stampProvider: any BibleNoteStampProvider = DefaultBibleNoteStampProvider()
    ) async {
        guard let noteRepository else { return }
        await registry.register(
            NoteBibleTool.registration(
                repository: noteRepository,
                clock: clock,
                ids: ids,
                stampProvider: stampProvider
            )
        )
    }

    /// No-op when user storage failed to open. Writes update the reader through its queries.
    public func registerHighlightTool(
        in registry: ToolRegistry,
        clock: any Clock = SystemClock()
    ) async {
        guard let highlightRepository else { return }
        await registry.register(
            HighlightBibleTool.registration(
                repository: highlightRepository,
                clock: clock
            )
        )
    }

    /// Registers read and search together; no-op when the bundled text database is unavailable.
    public func registerLookupTool(in registry: ToolRegistry) async {
        guard let textSearcher else { return }
        await registry.register(
            LookupBibleTool.registration(
                textLoader: DatabaseBibleTextLoader(),
                searcher: textSearcher,
                positionRepository: readingPositionRepository
            )
        )
    }

    /// Attach once during bootstrap; repeated observer attachment is harmless. Applet
    /// copies share the inbox and view model, so attaching before registry insertion is sufficient.
    public func attach(to bus: SuperEventBus) async {
        await referenceInbox.attach(to: bus)
        await viewModel.attach(to: bus)
        await viewModel.narration.settings?.attach(to: bus)
        await viewModel.narration.prepareDefaultVoice()
    }

    var _referenceInbox: BibleReferenceInbox { referenceInbox }

    /// Shares one runner between the Settings hub and background scheduler, preventing
    /// competing loops over the same ledger. Returns nil when user storage is unavailable.
    /// `currentModelID` records kickoff metadata; the dispatcher supplies each annotation's
    /// authoritative `.userBulk` stamp.
    @MainActor
    public func makeBulkAnnotationWiring(
        requiresCostConfirmation: Bool,
        generator: any BibleAnnotateGenerating,
        currentModelID: @escaping @Sendable () async -> String = { "" }
    ) -> BulkAnnotationWiring? {
        guard let databaseContext, let database else { return nil }
        let ledger = GRDBBulkAnnotationLedger(database: database)
        let annotationRepository = GRDBBibleAnnotationRepository(database: database)
        let runner = BulkAnnotationRunner(
            ledger: ledger,
            generator: generator,
            annotationRepository: annotationRepository,
            currentModelID: currentModelID
        )
        Task { await runner.restore() }
        // Clear through the runner's store so coverage queries refresh; log failures from this synchronous action.
        let contribution = BibleAnnotationsSettings.contribution(
            databaseContext: databaseContext,
            runner: runner,
            requiresCostConfirmation: requiresCostConfirmation,
            deleteAll: {
                Task {
                    do {
                        try await annotationRepository.deleteAll()
                    } catch {
                        bibleAppletLog.error(
                            "delete-all annotations failed: \(String(describing: error), privacy: .public)"
                        )
                    }
                }
            }
        )
        let background = BulkAnnotationBackgroundScheduler(runner: runner, ledger: ledger)
        return BulkAnnotationWiring(settingsContribution: contribution, background: background)
    }

    /// Shares the reader's read-only context without exposing BibleDatabase to the shell.
    public func makeBookmarksApplet() -> BibleBookmarksApplet {
        BibleBookmarksApplet(databaseContext: databaseContext)
    }

    @MainActor
    public func iconView(size: CGFloat) -> AnyView {
        AnyView(BibleAppletIcon(size: size))
    }

    @MainActor
    public func rootView() -> AnyView {
        let screen = BibleScreen(
            viewModel: viewModel,
            annotationRepository: annotationRepository
        )
        guard let databaseContext else { return AnyView(screen) }
        return AnyView(screen.databaseContext(databaseContext))
    }

    private static func openDatabase() -> BibleDatabase? {
        guard let directory = try? dataDirectory() else { return nil }
        return try? BibleDatabase.open(in: directory)
    }

    /// Pins the directory to `.complete` protection best-effort; BibleDatabase pins the
    /// database separately. SQLite sidecars use the app's default protection class, so
    /// stricter while-locked protection also requires a target default-data-protection entitlement.
    private static func dataDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appending(path: "Super", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: directory.path
        )
        return directory
    }
}
