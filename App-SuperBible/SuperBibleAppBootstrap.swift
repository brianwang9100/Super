import Bible
import Core
import Foundation
import SwiftUI

/// Dependency graph the SuperBible shell hands to its views.
///
/// SB-M0 stub: holds only the applet registry, which contains one
/// `BibleApplet()`. SB-M1 widens this with `ChatSessionStore`,
/// `LLMProviderRegistry`, `KeychainClient`, `SuperEventBus`, etc., once
/// Chat is registered as the host.
@MainActor
struct SuperBibleAppDependencies {
    let appletRegistry: AppletRegistry
}

/// One-shot composition root for the SuperBible target. Stays separate from
/// `SuperOSAppBootstrap` because the two apps register different applet
/// sets (Bible at SB-M0; Chat + Bible + Plans at SB-M1 and later).
///
/// Lives in `App-SuperBible/` (not in any package) for symmetry with
/// `App/SuperOSAppBootstrap.swift`.
enum SuperBibleAppBootstrap {
    /// Build the dependency graph.
    ///
    /// SB-M0 deliberately does no database opens, no Keychain access, no
    /// network calls, and no LLM provider hydration — the only thing it
    /// needs to do to launch the stub is to construct an applet registry
    /// containing `BibleApplet()` (which opens its own `bible.sqlite`
    /// inside its own `init`). Real bootstrap work lands at SB-M1.
    @MainActor
    static func bootstrap() async throws -> SuperBibleAppDependencies {
        let bible = BibleApplet()
        let registry = AppletRegistry(
            applets: [bible],
            initialActiveID: bible.appletID
        )
        return SuperBibleAppDependencies(appletRegistry: registry)
    }
}
