import Core
import GRDBQuery
import SwiftUI

/// Modal Settings sheet, presented as a native `.sheet` by the app shell
/// (the system supplies the scrim, drag bar, rounded surface, and slide /
/// drag-to-dismiss). This view is the sheet's content.
///
/// Sub-pane navigation lives on `SettingsViewModel.navigationPath` and is
/// driven by a `NavigationStack` — pushes get the native left-to-right
/// slide, and external callers can deep-link into a sub-pane (e.g. the
/// Chat composer opening `.modelDetail(id:)`) by mutating the path.
/// The sheet resets the path to empty on dismiss so re-presenting always
/// lands on `.root` — matching the React
/// `useEffect(() => { if (!open) setPane('root'); }, [open]);` reset.
public struct SettingsSheet: View {
    /// One pane in the sheet. The order tracks `settings.jsx`'s `setPane`
    /// switch with the new Tools, Compaction, and Model Detail destinations
    /// slotted in. `Hashable` so `NavigationStack` can route on it.
    public enum Pane: Hashable, Sendable {
        case root
        case models
        /// Model create/edit form. `nil` id ⇒ new model. The id parameter
        /// is the existing record id for edit mode.
        case modelDetail(id: String?)
        case personalization
        case verbosity
        case appearance
        case tools
        /// Per-tool configuration pane for the `memory` tool — view /
        /// edit / delete saved memories. Reached by tapping the gear
        /// affordance on the Memory row in `.tools`.
        case memory
        case compaction
        /// Global web-search preferences — currently the native cost-gate
        /// toggle ("Ask before each search"). Phase 2 expands this pane
        /// with standalone search-provider config + keys.
        case search
        case data
        case about
        /// A pane contributed by an applet (e.g. Bible's "Annotations"),
        /// resolved against `\.appletSettingsContributions`. Carries its own
        /// title so the header renders without the host knowing the applet.
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

    /// Two-way binding controlling visibility. The close button flips it to
    /// `false`; the native sheet also flips it on a drag-down dismiss.
    @Binding public var isPresented: Bool

    /// Shared state owner. The host owns the instance so the sheet keeps
    /// a stable identity across presentations and so external callers can
    /// deep-link by mutating `viewModel.navigationPath`.
    @Bindable public var viewModel: SettingsViewModel

    /// Read-only access to `chat.sqlite` for sub-panes that bind data
    /// reactively via GRDBQuery `@Query` (currently `SettingsMemoryPane`,
    /// which must repaint when the LLM writes to the memory table from
    /// outside the pane). `nil` in snapshot tests and previews —
    /// `@Query` then falls back to the request's `defaultValue`.
    public let databaseContext: DatabaseContext?

    @Environment(\.superTheme) private var theme
    /// Applet-contributed settings surfaces (e.g. Bible's Annotations pane),
    /// injected by the composition root. Empty in previews/tests.
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

    /// Test seam: lets snapshot tests render any sub-pane without
    /// programmatically driving the navigation stack. Internal so the SDK
    /// surface still presents a single public `init`. Seeds the view
    /// model's path so the first render lands on `initialPane` without
    /// animation. `initialModelDetailSelection` lets a modelDetail snapshot
    /// pin a starting provider other than `.custom` so the per-provider
    /// prefilled create-flow states can be captured.
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

    /// Backing value for the internal `initialModelDetailSelection`
    /// test seam. `paneContent` forwards it to the modelDetail case so
    /// a pinned selection is honored even after a navigation push.
    private var initialModelDetailSelection: SettingsModelDetailPane.InitialSelection = .custom
    /// Backing value for the internal `initialModelDetailContextWindowError`
    /// test seam — lets a snapshot capture the inline-error state
    /// without simulating a Save tap.
    private var initialModelDetailContextWindowError: String?
    /// Backing value for the internal `initialModelDetailAPIKey` test
    /// seam — seeds the create-mode key field so a snapshot renders the
    /// unlocked (key-entered) state without driving the SecureField.
    private var initialModelDetailAPIKey: String?

    public var body: some View {
        sheetSurface
            .accessibilityAction(.escape) { close() }
            // The native `.sheet` creates this view fresh on each presentation,
            // so a plain `.task` loads exactly once per present (and cancels on
            // dismiss when the view tears down) — no `id:` gate needed.
            .task { await viewModel.load() }
            // Apply the read-only database context only when the host wired
            // one — snapshot tests and previews pass nil and fall through to
            // each `@Query` request's defaultValue. The `databaseContext`
            // ViewModifier requires a value, so we apply a no-op pass through
            // an inline overload when nil.
            .modifier(OptionalDatabaseContextModifier(context: databaseContext))
    }

    private func close() {
        // Flipping the binding dismisses the native sheet; the host's
        // `.sheet(onDismiss:)` calls `popToRoot()` — the single reset site that
        // covers both this close-button path and a drag-down dismiss, so the
        // nav stack isn't reset twice (and the deep pane stays visible through
        // the dismiss animation rather than snapping to root first).
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
                // The Models pane carries a trailing glass "+" that opens the
                // add-model form, replacing the in-list dashed CTA.
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
        // Top room for the system drag indicator; the native sheet supplies the
        // rounded surface, scrim, and elevation the custom chrome used to draw.
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

/// Apply the GRDBQuery read-only `DatabaseContext` when one is wired,
/// otherwise pass the content through unchanged. Lets snapshot tests
/// render the sheet without spinning up a database queue while
/// production wires the real chat-database context.
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

/// Hides the system navigation bar on iOS so the custom `SettingsHeader`
/// is the only chrome above the pane content. macOS doesn't have a
/// navigation bar in this sense — the modifier is a no-op there. Lives
/// inline with `SettingsSheet` because no other surface needs it.
private struct HiddenNavigationBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbar(.hidden, for: .navigationBar)
        #else
        content
        #endif
    }
}

/// Bridge between `ChatSettings.ThemeID` (persisted enum) and
/// `SuperTheme.Identifier` (palette factory enum). They mirror each other
/// today; the bridge keeps either side free to add a case the other
/// doesn't know about yet.
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

/// Bridge between `ChatSettings.TypographyID` (persisted enum) and
/// `SuperTypography.Identifier` (face-set factory enum), folding in the
/// active font scale so call sites read one environment value. Mirrors the
/// `SuperTheme` bridge above; both sides stay free to add a case the other
/// doesn't know about yet.
public extension SuperTypography {
    static func make(_ id: ChatSettings.TypographyID, fontScale: Double = 1) -> SuperTypography {
        let scale = CGFloat(fontScale)
        switch id {
        case .serif: return .make(SuperTypography.Identifier.serif, fontScale: scale)
        case .system: return .make(SuperTypography.Identifier.system, fontScale: scale)
        }
    }
}
