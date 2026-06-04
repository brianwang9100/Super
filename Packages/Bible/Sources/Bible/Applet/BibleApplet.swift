import Core
import Foundation
import GRDBQuery
import SwiftUI

/// The Bible mini-applet entry point. Registered with the shell's
/// `AppletRegistry` at composition root; the shell renders `rootView()`
/// behind the chat overlay.
///
/// The applet owns one `BibleScreenViewModel` for the lifetime of the
/// registry entry, so the reader's place survives re-renders of the backdrop.
/// It also holds the read-only `DatabaseContext` injected into the SwiftUI
/// environment so the chapter renderer's highlight `@Query` can observe the
/// `bibleHighlight` table.
public struct BibleApplet: MiniApplet {
    /// Stable, lowercase identifier — used for routing, settings keys, and
    /// deep-link URIs (`super://bible/<recordID>`).
    public static let appletID: String = "bible"
    public var appletID: String { Self.appletID }
    public var displayName: String { "Bible" }
    /// Muted plum, matching the prior placeholder so the sidebar glyph and
    /// chat-card accent strips don't shift visually on upgrade.
    public static let accentColor: Color = Color(red: 0.52, green: 0.32, blue: 0.55)
    public var accentColor: Color { Self.accentColor }
    public var systemPrompt: String { AppletSystemPrompt.load(from: .module) }

    /// The single view model backing the reading surface. Held here (not
    /// rebuilt per `rootView()` call) so navigation state persists while the
    /// applet is the active backdrop.
    private let viewModel: BibleScreenViewModel

    /// App-session subscriber that routes inbound Bible deep links (Chat
    /// citation taps + external `super://` URLs) onto `viewModel`. The
    /// composition root calls `attach(to:)` once during bootstrap; until
    /// then the inbox holds the viewModel ref but has no subscription.
    private let referenceInbox: BibleReferenceInbox

    /// Read-only database access for the chapter renderer's highlight
    /// `@Query`, injected into the SwiftUI environment by `rootView()`. `nil`
    /// when the database failed to open — the reader then shows no highlights
    /// rather than failing outright.
    private let databaseContext: DatabaseContext?

    /// The applet's `bible.sqlite` handle, retained so the bulk-annotation
    /// runner can build its `GRDBBulkAnnotationLedger` from it without the
    /// database leaking past the applet. `nil` when the database failed to open.
    private let database: BibleDatabase?

    /// Write seam for the `bible.annotate` tool. `nil` when the database
    /// failed to open at init; `registerAnnotationTool(in:)` then becomes
    /// a no-op so the rest of the reader still loads.
    private let annotationRepository: (any BibleAnnotationRepository)?

    /// Write seam for the `bible.note` tool. `nil` when the database failed
    /// to open at init; `registerNoteTool(in:)` then becomes a no-op so the
    /// rest of the reader still loads.
    private let noteRepository: (any BibleNoteRepository)?

    /// Production entry point — bundled text plus an on-disk store under
    /// Application Support for the reading position and verse highlights.
    ///
    /// The database opens synchronously here: it is three small tables
    /// behind three tiny migrations, and the applet is built in each
    /// target's bootstrap (`SuperOSAppBootstrap` / `SuperBibleAppBootstrap`)
    /// where no `async` context exists. Should the Bible schema ever grow
    /// heavy, move this open into the bootstrap alongside `ChatDatabase`
    /// rather than blocking the launch path.
    @MainActor
    public init() {
        let database = BibleApplet.openDatabase()
        self.database = database
        self.databaseContext = database.map { db in
            DatabaseContext.readOnly { db.queue }
        }
        self.annotationRepository = database.map { GRDBBibleAnnotationRepository(database: $0) }
        // One note repository instance shared by the `bible.note` tool
        // (`registerNoteTool`) and the view model's note CRUD — both point at
        // the same `bible.sqlite` queue, so a single instance avoids a latent
        // divergence if the repository ever gains instance-level state.
        let noteRepository = database.map { GRDBBibleNoteRepository(database: $0) }
        self.noteRepository = noteRepository
        // TODO(narration-arbitration): Wire a shell-side
        // `NarrationAudioCoordinator` adapter that reads from Chat's
        // `VoiceInputController`. The default `BibleScreenViewModel`
        // init constructs an `AVSpeechSynthesizerNarrationService`
        // with `coordinator: nil`, so the preempt-on-active-mic check
        // is a no-op in production today. The adapter needs to live
        // at the composition root (`SuperOSAppBootstrap`) to bridge Bible →
        // Chat without violating the no-cross-applet-imports rule.
        let viewModel = BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            positionRepository: database.map { GRDBBibleReadingPositionRepository(database: $0) },
            highlightRepository: database.map { GRDBBibleHighlightRepository(database: $0) },
            noteRepository: noteRepository
        )
        self.viewModel = viewModel
        self.referenceInbox = BibleReferenceInbox(viewModel: viewModel)
    }

    /// Test seam: inject a view model wired to in-memory doubles so a test
    /// never touches the real on-disk database. The highlight `@Query` runs
    /// without a database context — it falls back to an empty result.
    @MainActor
    init(
        viewModel: BibleScreenViewModel,
        databaseContext: DatabaseContext? = nil,
        annotationRepository: (any BibleAnnotationRepository)? = nil,
        noteRepository: (any BibleNoteRepository)? = nil
    ) {
        self.viewModel = viewModel
        self.referenceInbox = BibleReferenceInbox(viewModel: viewModel)
        self.database = nil
        self.databaseContext = databaseContext
        self.annotationRepository = annotationRepository
        self.noteRepository = noteRepository
    }

    /// Register the `bible.annotate` tool with the given registry, using
    /// this applet's local database. No-op if the database failed to open
    /// at init — the reader still loads, just without the tool.
    ///
    /// Called from each app's bootstrap (`SuperBibleAppBootstrap` /
    /// `SuperOSAppBootstrap`), mirroring how Chat ships `TimeNowTool` and
    /// `MemoryTool`. Tool ownership stays with the applet so the
    /// Bible-internal `BibleDatabase` + repository never leak into the
    /// composition root.
    ///
    /// `stampProvider` is required (no default) so a new composition root
    /// must consciously choose one — passing the active-model provider in
    /// production, never silently defaulting to the empty-modelId fallback
    /// (which would resurrect the "Generated by AI" bug).
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

    /// Register the `bible.note` tool with the given registry, using this
    /// applet's local database. No-op if the database failed to open at init.
    ///
    /// Called from each app's bootstrap alongside `registerAnnotationTool`,
    /// so the assistant can create / edit / delete notes during a chat turn.
    /// Tool ownership stays with the applet so the Bible-internal
    /// `BibleDatabase` + repository never leak into the composition root.
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

    /// Subscribe the applet to the shared event bus on `bus`. Called
    /// once per composition root after the shared `SuperEventBus` is
    /// constructed. Idempotent — both observers no-op on a second
    /// attach. Wires:
    ///
    /// - `BibleReferenceInbox` for inbound Bible deep links from Chat.
    /// - `BibleScreenViewModel` for headless `bibleAnnotateCompleted`
    ///   envelopes so the per-target dispatch table flips on
    ///   completion (success removes the entry; failure flips to a
    ///   retry-button state).
    ///
    /// Applet struct copies share the same `referenceInbox` and
    /// `viewModel` references (both classes), so calling this on the
    /// locally-held value before the struct is moved into the
    /// `AppletRegistry` is sufficient.
    public func attach(to bus: SuperEventBus) async {
        await referenceInbox.attach(to: bus)
        await viewModel.attach(to: bus)
    }

    /// Test seam exposing the inbox so a test can publish events through
    /// a real in-memory bus and assert the view-model side-effect.
    /// Underscore prefix marks this as not part of the stable public
    /// API, matching the convention used by other applets.
    var _referenceInbox: BibleReferenceInbox { referenceInbox }

    /// The "Annotations" entry for the shared Settings screen, backed by the
    /// in-memory `FakeBulkAnnotationRunner` — the fallback for previews, tests,
    /// or a shell that doesn't wire real bulk generation. The production path
    /// (SuperBible) uses `makeBulkAnnotationWiring(…)` instead, which builds the
    /// LLM-backed runner. `nil` when the database failed to open.
    @MainActor
    public func annotationsSettingsContribution(
        requiresCostConfirmation: Bool
    ) -> AppletSettingsContribution? {
        guard let databaseContext else { return nil }
        return BibleAnnotationsSettings.contribution(
            databaseContext: databaseContext,
            runner: FakeBulkAnnotationRunner(),
            requiresCostConfirmation: requiresCostConfirmation
        )
    }

    /// The full bulk-annotation wiring for the production shell: the Settings
    /// hub contribution **and** the background scheduler, both driving a single
    /// shared `BulkAnnotationRunner` over the applet's `bible.sqlite` ledger.
    ///
    /// Built here (rather than at the composition root) so the Bible-internal
    /// `BibleDatabase` + `GRDBBulkAnnotationLedger` never leak — only the
    /// Core-typed `generator` crosses the seam, mirroring
    /// `registerAnnotationTool(in:)`. One runner backs both the foreground hub
    /// and the background task, so the two never run competing loops over the
    /// same run rows. `nil` when the database failed to open.
    ///
    /// - Parameters:
    ///   - generator: the cross-package generation seam (Bible can't import
    ///     Chat, so the dispatcher arrives as a Core `BibleAnnotateGenerating`).
    ///   - currentModelID: resolves the model active at run kickoff for the run
    ///     record's `modelId` metadata (the registry is actor-isolated, hence
    ///     async). The authoritative per-annotation stamp is still the
    ///     dispatcher's `.userBulk` stamp provider.
    @MainActor
    public func makeBulkAnnotationWiring(
        requiresCostConfirmation: Bool,
        generator: any BibleAnnotateGenerating,
        currentModelID: @escaping @Sendable () async -> String = { "" }
    ) -> BulkAnnotationWiring? {
        guard let databaseContext, let database else { return nil }
        let ledger = GRDBBulkAnnotationLedger(database: database)
        let runner = BulkAnnotationRunner(
            ledger: ledger,
            generator: generator,
            currentModelID: currentModelID
        )
        // Resume an in-progress run on launch (no-op when none is active).
        Task { await runner.restore() }
        let contribution = BibleAnnotationsSettings.contribution(
            databaseContext: databaseContext,
            runner: runner,
            requiresCostConfirmation: requiresCostConfirmation
        )
        let background = BulkAnnotationBackgroundScheduler(runner: runner, ledger: ledger)
        return BulkAnnotationWiring(settingsContribution: contribution, background: background)
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

    /// Opens the Bible database, or returns `nil` if it can't be created — the
    /// reader then runs without relaunch restore or highlight persistence
    /// rather than failing outright.
    private static func openDatabase() -> BibleDatabase? {
        guard let directory = try? dataDirectory() else { return nil }
        return try? BibleDatabase.open(in: directory)
    }

    /// `Application Support/Super/`, created if missing — the same directory
    /// the shell uses for `chat.sqlite`. The `.complete` protection class is
    /// applied here (best-effort, iOS-enforced) so the directory itself is
    /// pinned. The on-disk `bible.sqlite` is independently pinned to
    /// `.complete` inside `BibleDatabase.open(in:)`, mirroring the host
    /// app's `AppBootstrapSupport.ensureDirectoryExists` + `ChatDatabase.open`
    /// pattern (shared by both `SuperOSAppBootstrap` and
    /// `SuperBibleAppBootstrap`). The `-wal` / `-shm` sidecars SQLite creates at runtime fall
    /// back to the app's default protection class (iOS defaults to
    /// `.completeUntilFirstUserAuthentication`, not `.none` — see Apple's
    /// File-System Data Protection guide). If stricter "encrypted while
    /// locked" semantics are needed for the sidecars too, the bulletproof
    /// fix is adding `com.apple.developer.default-data-protection =
    /// NSFileProtectionComplete` to the target entitlements — tracked as
    /// an SB-M4 hardening item in `TODO.md`.
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
