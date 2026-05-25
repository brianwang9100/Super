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

    /// Read-only database access for the chapter renderer's highlight
    /// `@Query`, injected into the SwiftUI environment by `rootView()`. `nil`
    /// when the database failed to open — the reader then shows no highlights
    /// rather than failing outright.
    private let databaseContext: DatabaseContext?

    /// Production entry point — bundled text plus an on-disk store under
    /// Application Support for the reading position and verse highlights.
    ///
    /// The database opens synchronously here: it is two small tables behind
    /// two tiny migrations, and the applet is built in `ContentView`'s
    /// initializer where no `async` context exists. Should the Bible schema
    /// ever grow heavy, move this open to `SuperOSAppBootstrap` alongside
    /// `ChatDatabase` rather than blocking the launch path.
    @MainActor
    public init() {
        let database = BibleApplet.openDatabase()
        self.databaseContext = database.map { db in
            DatabaseContext.readOnly { db.queue }
        }
        // TODO(narration-arbitration): Wire a shell-side
        // `NarrationAudioCoordinator` adapter that reads from Chat's
        // `VoiceInputController`. The default `BibleScreenViewModel`
        // init constructs an `AVSpeechSynthesizerNarrationService`
        // with `coordinator: nil`, so the preempt-on-active-mic check
        // is a no-op in production today. The adapter needs to live
        // at the composition root (`SuperOSAppBootstrap`) to bridge Bible →
        // Chat without violating the no-cross-applet-imports rule.
        self.viewModel = BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            positionRepository: database.map { GRDBBibleReadingPositionRepository(database: $0) },
            highlightRepository: database.map { GRDBBibleHighlightRepository(database: $0) }
        )
    }

    /// Test seam: inject a view model wired to in-memory doubles so a test
    /// never touches the real on-disk database. The highlight `@Query` runs
    /// without a database context — it falls back to an empty result.
    @MainActor
    init(viewModel: BibleScreenViewModel, databaseContext: DatabaseContext? = nil) {
        self.viewModel = viewModel
        self.databaseContext = databaseContext
    }

    @MainActor
    public func iconView(size: CGFloat) -> AnyView {
        AnyView(BibleAppletIcon(size: size))
    }

    @MainActor
    public func rootView() -> AnyView {
        let screen = BibleScreen(viewModel: viewModel)
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
    /// app's `AppBootstrapHelpers.ensureDirectoryExists` + `ChatDatabase.open`
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
