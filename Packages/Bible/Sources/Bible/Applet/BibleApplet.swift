import Core
import Foundation
import SwiftUI

/// The Bible mini-applet entry point. Registered with the shell's
/// `AppletRegistry` at composition root; the shell renders `rootView()`
/// behind the chat overlay.
///
/// M2 adds chapter navigation and reading-position persistence: the applet
/// owns one `BibleScreenViewModel` for the lifetime of the registry entry,
/// so the reader's place survives re-renders of the backdrop.
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

    /// The single view model backing the reading surface. Held here (not
    /// rebuilt per `rootView()` call) so navigation state persists while the
    /// applet is the active backdrop.
    private let viewModel: BibleScreenViewModel

    /// Production entry point — bundled text plus an on-disk reading-position
    /// store under Application Support.
    @MainActor
    public init() {
        self.viewModel = BibleApplet.makeViewModel()
    }

    /// Test seam: inject a view model wired to in-memory doubles so a test
    /// never touches the real on-disk database.
    @MainActor
    init(viewModel: BibleScreenViewModel) {
        self.viewModel = viewModel
    }

    @MainActor
    public func iconView(size: CGFloat) -> AnyView {
        AnyView(BibleAppletIcon(size: size))
    }

    @MainActor
    public func rootView() -> AnyView {
        AnyView(BibleScreen(viewModel: viewModel))
    }

    @MainActor
    private static func makeViewModel() -> BibleScreenViewModel {
        BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            positionRepository: makeRepository()
        )
    }

    /// Opens the reading-position database, or returns `nil` if it can't be
    /// created — the reader then runs without relaunch restore rather than
    /// failing outright.
    private static func makeRepository() -> (any BibleReadingPositionRepository)? {
        guard let directory = try? dataDirectory(),
              let database = try? BibleDatabase.open(in: directory) else {
            return nil
        }
        return GRDBBibleReadingPositionRepository(database: database)
    }

    /// `Application Support/Super/`, created if missing — the same directory
    /// the shell uses for `chat.sqlite`.
    private static func dataDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appending(path: "Super", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
