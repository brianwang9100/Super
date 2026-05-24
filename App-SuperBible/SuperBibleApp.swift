import Bible
import Core
import SwiftUI

/// Composition root + shell entry point for the SuperBible App Store target.
/// Bootstraps the dependency graph once per process and feeds it to
/// `SuperBibleContentView`. Mirrors `SuperOSApp` deliberately so the two
/// `@main` files stay structurally analogous — every change to the launch
/// pattern should land in both.
///
/// SB-M0 stub: registers a single `BibleApplet()` and renders its root view
/// directly. SB-M1 widens the dependency container, adds Chat as host, and
/// brings in the real shell.
@main
struct SuperBibleApp: App {
    @State private var state: SuperBibleBootstrapState = .loading

    init() {
        // Register Instrument Serif Italic + JetBrains Mono Regular before
        // SwiftUI's first render. Idempotent and shared with SuperOS — both
        // apps consume the same Core font registration.
        Core.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            SuperBibleContentView(state: state)
                .task {
                    if case .loading = state {
                        await load()
                    }
                }
        }
    }

    private func load() async {
        do {
            let dependencies = try await SuperBibleAppBootstrap.bootstrap()
            state = .ready(dependencies)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// Three-state launch machine, parallel to SuperOS's `BootstrapState`. A
/// SuperBible-specific copy (rather than a shared type in Core) keeps the
/// two targets' associated-value types — `SuperBibleAppDependencies` here
/// vs SuperOS's `AppDependencies` — from collapsing into a generic.
enum SuperBibleBootstrapState {
    case loading
    case ready(SuperBibleAppDependencies)
    case failed(String)
}
