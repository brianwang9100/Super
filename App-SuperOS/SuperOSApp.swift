import Chat
import Core
import SwiftUI

/// Bootstrap in a task so database/Keychain failures surface as UI instead of crashing launch.
@main
struct SuperOSApp: App {
    @State private var state: SuperOSBootstrapState = .loading
    @State private var isBootstrapping = false

    init() {
        // Register bundled fonts before the first SwiftUI render.
        Core.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            SuperOSContentView(state: state)
                .task {
                    if case .loading = state {
                        await load()
                    }
                }
        }
    }

    private func load() async {
        guard case .loading = state, !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }
        do {
            let dependencies = try await SuperOSAppBootstrap.bootstrap()
            state = .ready(dependencies)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

enum SuperOSBootstrapState {
    case loading
    case ready(SuperOSAppDependencies)
    case failed(String)

    /// Supports case-transition animation without making the dependency graph Equatable.
    var discriminant: Int {
        switch self {
        case .loading: 0
        case .ready: 1
        case .failed: 2
        }
    }
}
