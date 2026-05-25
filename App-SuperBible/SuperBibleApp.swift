import Bible
import Core
import SwiftUI

/// Composition root + shell entry point for the SuperBible App Store
/// target. Bootstraps the dependency graph once per process and feeds it
/// to `SuperBibleContentView`. Mirrors `SuperOSApp` deliberately so the
/// two `@main` files stay structurally analogous — every change to the
/// launch pattern should land in both.
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

/// Three-state launch machine, parallel to SuperOS's `SuperOSBootstrapState`.
/// A SuperBible-specific copy (rather than a shared type in Core) keeps the
/// two targets' associated-value types — `SuperBibleAppDependencies` here
/// vs SuperOS's `SuperOSAppDependencies` — from collapsing into a generic.
enum SuperBibleBootstrapState {
    case loading
    case ready(SuperBibleAppDependencies)
    case failed(String)

    /// Stable identity for the case (ignoring the associated value) so
    /// `.animation(value:)` can observe state transitions in the content
    /// view without forcing the dependency type to be `Equatable`.
    /// Matches SuperOS's `SuperOSBootstrapState.discriminant`.
    var discriminant: Int {
        switch self {
        case .loading: 0
        case .ready: 1
        case .failed: 2
        }
    }
}
