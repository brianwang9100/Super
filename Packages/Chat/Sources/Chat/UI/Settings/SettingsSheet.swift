import Core
import GRDBQuery
import SwiftUI

public struct SettingsSheet: View {
    public enum Pane: Hashable, Sendable {
        case root
        case models
        /// Nil creates a model; otherwise edit the record with this ID.
        case modelDetail(id: String?)
        case personalization
        case verbosity
        case appearance
        case tools
        case memory
        case compaction
        case search
        case data
        case about
        case appletContributed(id: String, title: String)

        var title: String {
            switch self {
            case .appletContributed(_, let title): return title
            case .root: return "Settings"
            case .models: return "Models"
            case .modelDetail(let id): return id == nil ? "Add Model" : "Edit Model"
            case .personalization: return "Personalization"
            case .verbosity: return "Default Verbosity"
            case .appearance: return "Look & Feel"
            case .tools: return "Tools"
            case .memory: return "Memory"
            case .compaction: return "Compaction"
            case .search: return "Search"
            case .data: return "Data"
            case .about: return "About"
            }
        }
    }

    @Binding public var isPresented: Bool

    @Bindable public var viewModel: SettingsViewModel

    /// Supplies reactive pane queries; nil uses their default values for previews and snapshots.
    public let databaseContext: DatabaseContext?

    @Environment(\.superTheme) private var theme
    @Environment(\.appletSettingsContributions) private var appletContributions

    public init(
        isPresented: Binding<Bool>,
        viewModel: SettingsViewModel,
        databaseContext: DatabaseContext? = nil
    ) {
        self._isPresented = isPresented
        self.viewModel = viewModel
        self.databaseContext = databaseContext
    }

    /// Snapshot seam for initial navigation and model-form state without simulated interaction.
    init(
        isPresented: Binding<Bool>,
        viewModel: SettingsViewModel,
        initialPane: Pane,
        initialModelDetailSelection: SettingsModelDetailPane.InitialSelection = .custom,
        initialModelDetailContextWindowError: String? = nil,
        initialModelDetailAPIKey: String? = nil,
        databaseContext: DatabaseContext? = nil
    ) {
        self._isPresented = isPresented
        self.viewModel = viewModel
        self.databaseContext = databaseContext
        self.initialModelDetailSelection = initialModelDetailSelection
        self.initialModelDetailContextWindowError = initialModelDetailContextWindowError
        self.initialModelDetailAPIKey = initialModelDetailAPIKey
        if initialPane != .root {
            viewModel.navigationPath = [initialPane]
        }
    }

    private var initialModelDetailSelection: SettingsModelDetailPane.InitialSelection = .custom
    private var initialModelDetailContextWindowError: String?
    private var initialModelDetailAPIKey: String?

    public var body: some View {
        sheetSurface
            .accessibilityAction(.escape) { close() }
            .task { await viewModel.load() }
            .modifier(OptionalDatabaseContextModifier(context: databaseContext))
    }

    private func close() {
        // Reset navigation in the host's onDismiss, after animation, for both close and drag dismissal.
        isPresented = false
    }

    private var currentPane: Pane {
        viewModel.navigationPath.last ?? viewModel.rootPane
    }

    @ViewBuilder
    private var sheetSurface: some View {
        VStack(spacing: 0) {
            SettingsHeader(
                title: currentPane.title,
                isRoot: viewModel.navigationPath.isEmpty,
                onBack: { viewModel.popPane() },
                onClose: { close() },
                trailingAction: currentPane == .models
                    ? { viewModel.openPane(.modelDetail(id: nil)) }
                    : nil,
                trailingAccessibilityLabel: currentPane == .models ? "Add model endpoint" : nil
            )
            NavigationStack(path: $viewModel.navigationPath) {
                ScrollView {
                    paneContent(viewModel.rootPane)
                }
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)
                .background(theme.background)
                .modifier(HiddenNavigationBarModifier())
                .navigationDestination(for: Pane.self) { pane in
                    ScrollView {
                        paneContent(pane)
                    }
                    .scrollIndicators(.hidden)
                    .scrollContentBackground(.hidden)
                    .background(theme.background)
                    .modifier(HiddenNavigationBarModifier())
                }
            }
        }
        // Clear the system drag indicator.
        .padding(.top, 8)
        .background(theme.background)
    }

    @ViewBuilder
    private func paneContent(_ pane: Pane) -> some View {
        switch pane {
        case .root:
            SettingsRootPane(viewModel: viewModel)
        case .models:
            SettingsModelsPane(viewModel: viewModel)
        case .modelDetail(let id):
            SettingsModelDetailPane(
                viewModel: viewModel,
                editingId: id,
                initialSelection: initialModelDetailSelection,
                initialContextWindowError: initialModelDetailContextWindowError,
                initialAPIKey: initialModelDetailAPIKey
            )
        case .personalization:
            SettingsPersonalizationPane(viewModel: viewModel)
        case .verbosity:
            SettingsVerbosityPane(viewModel: viewModel)
        case .appearance:
            SettingsAppearancePane(viewModel: viewModel)
        case .tools:
            SettingsToolsPane(viewModel: viewModel)
        case .memory:
            SettingsMemoryPane(viewModel: viewModel)
        case .compaction:
            SettingsCompactionPane(viewModel: viewModel)
        case .search:
            SettingsSearchPane(viewModel: viewModel)
        case .data:
            SettingsDataPane(viewModel: viewModel)
        case .about:
            SettingsAboutPane(viewModel: viewModel)
        case .appletContributed(let id, _):
            if let contribution = appletContributions.first(where: { $0.id == id }) {
                contribution.makeDestination()
            } else {
                EmptyView()
            }
        }
    }
}

private struct OptionalDatabaseContextModifier: ViewModifier {
    let context: DatabaseContext?
    func body(content: Content) -> some View {
        if let context {
            content.databaseContext(context)
        } else {
            content
        }
    }
}

private struct HiddenNavigationBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbar(.hidden, for: .navigationBar)
        #else
        content
        #endif
    }
}

public extension SuperTheme {
    static func make(_ id: ChatSettings.ThemeID) -> SuperTheme {
        switch id {
        case .vellumLight: return .make(SuperTheme.Identifier.vellumLight)
        case .vellumDark: return .make(SuperTheme.Identifier.vellumDark)
        case .lapisLight: return .make(SuperTheme.Identifier.lapisLight)
        case .lapisDark: return .make(SuperTheme.Identifier.lapisDark)
        case .scriptoriumLight: return .make(SuperTheme.Identifier.scriptoriumLight)
        case .scriptoriumDark: return .make(SuperTheme.Identifier.scriptoriumDark)
        case .slateLight: return .make(SuperTheme.Identifier.slateLight)
        case .slateDark: return .make(SuperTheme.Identifier.slateDark)
        }
    }
}

public extension SuperTypography {
    static func make(_ id: ChatSettings.TypographyID, fontScale: Double = 1) -> SuperTypography {
        let scale = CGFloat(fontScale)
        switch id {
        case .serif: return .make(SuperTypography.Identifier.serif, fontScale: scale)
        case .system: return .make(SuperTypography.Identifier.system, fontScale: scale)
        }
    }
}
