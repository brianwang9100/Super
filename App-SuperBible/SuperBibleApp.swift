import Bible
import Core
import SwiftUI

@main
struct SuperBibleApp: App {
    @State private var state: SuperBibleBootstrapState = .loading
    @State private var isBootstrapping = false
    @Environment(\.scenePhase) private var scenePhase

    /// Register before launch completes; attach the live scheduler after bootstrap.
    private let backgroundController = BulkAnnotationBackgroundController()

    init() {
        // Register bundled fonts before the first SwiftUI render.
        Core.registerBundledFonts()
        backgroundController.registerLaunchHandler()
    }

    var body: some Scene {
        WindowGroup {
            SuperBibleContentView(state: state)
                .task {
                    if case .loading = state {
                        await load()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // This observer outlives the Bible backdrop, so narration is
                    // stopped even after switching to another applet.
                    if phase != .active, case .ready(let dependencies) = state {
                        dependencies.audioActivity.stopPlayback?()
                    }
                    switch phase {
                    case .background:
                        backgroundController.applicationDidEnterBackground()
                    case .active:
                        backgroundController.applicationDidBecomeActive()
                    default:
                        break
                    }
                }
        }
    }

    private func load() async {
        guard case .loading = state, !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }
        do {
            let dependencies = try await SuperBibleAppBootstrap.bootstrap()
            backgroundController.attach(dependencies.bulkAnnotationBackground)
            state = .ready(dependencies)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

enum SuperBibleBootstrapState {
    case loading
    case ready(SuperBibleAppDependencies)
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
