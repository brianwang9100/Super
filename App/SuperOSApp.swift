import Chat
import Core
import SwiftUI

/// Composition root + shell entry point. Bootstraps the dependency graph once
/// per process and feeds it to `ContentView`. The bootstrap runs in a `.task`
/// rather than the initializer so any GRDB or Keychain failure surfaces as
/// UI rather than a crashed launch.
@main
struct SuperOSApp: App {
    @State private var state: BootstrapState = .loading

    init() {
        // Register Instrument Serif Italic + JetBrains Mono Regular before
        // SwiftUI's first render — `SplashView` and the chat chrome both
        // ask for them via `Font.custom(...)`. The call is idempotent.
        Core.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .task {
                    if case .loading = state {
                        await load()
                    }
                }
        }
    }

    private func load() async {
        do {
            let dependencies = try await SuperOSAppBootstrap.bootstrap()
            state = .ready(dependencies)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// Three-state machine for the launch sequence. The Shell shows a placeholder
/// during `loading` and a hard-error pane during `failed`; everything else is
/// driven from `ready(_:)`.
enum BootstrapState {
    case loading
    case ready(AppDependencies)
    case failed(String)

    /// Stable identity for the case (ignoring the associated value) so
    /// `.animation(value:)` can observe state transitions without forcing
    /// `AppDependencies` to be `Equatable`.
    var discriminant: Int {
        switch self {
        case .loading: 0
        case .ready: 1
        case .failed: 2
        }
    }
}
