import Core
import SwiftUI

/// Modal Settings sheet. Mirrors `SettingsModal` from `settings.jsx`:
/// 25%-black scrim + a bottom-sheet that slides up to a 40pt top inset
/// with a 22pt top-corner radius. Reduce Motion swaps the slide for an
/// opacity fade.
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
        case theme
        case prompt
        case verbosity
        case appearance
        case tools
        case compaction
        case data
        case about

        var title: String {
            switch self {
            case .root: return "Settings"
            case .models: return "Models"
            case .modelDetail(let id): return id == nil ? "Add Model" : "Edit Model"
            case .theme: return "Theme"
            case .prompt: return "System Prompt"
            case .verbosity: return "Default Verbosity"
            case .appearance: return "Appearance"
            case .tools: return "Tools"
            case .compaction: return "Compaction"
            case .data: return "Data"
            case .about: return "About"
            }
        }
    }

    /// Two-way binding controlling visibility. The sheet flips it to
    /// `false` whenever the user taps the scrim or the close button.
    @Binding public var isPresented: Bool

    /// Shared state owner. The host owns the instance so the sheet keeps
    /// a stable identity across presentations and so external callers can
    /// deep-link by mutating `viewModel.navigationPath`.
    @Bindable public var viewModel: SettingsViewModel

    @Environment(\.superTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        isPresented: Binding<Bool>,
        viewModel: SettingsViewModel
    ) {
        self._isPresented = isPresented
        self.viewModel = viewModel
    }

    /// Test seam: lets snapshot tests render any sub-pane without
    /// programmatically driving the navigation stack. Internal so the SDK
    /// surface still presents a single public `init`. Seeds the view
    /// model's path so the first render lands on `initialPane` without
    /// animation.
    init(
        isPresented: Binding<Bool>,
        viewModel: SettingsViewModel,
        initialPane: Pane
    ) {
        self._isPresented = isPresented
        self.viewModel = viewModel
        if initialPane != .root {
            viewModel.navigationPath = [initialPane]
        }
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            if isPresented {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .transition(.opacity)
                    .accessibilityHidden(true)

                sheetSurface
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape) { close() }
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .timingCurve(0.32, 0.72, 0, 1, duration: 0.30), value: isPresented)
        .task(id: isPresented) {
            if isPresented {
                await viewModel.load()
            }
        }
    }

    private func close() {
        isPresented = false
        // Reset the nav stack so re-presenting the sheet always lands on
        // root. The sheet subtree is removed when `isPresented` flips, so
        // resetting the shared view-model state here is what produces the
        // React `useEffect(...)` reset behavior.
        viewModel.popToRoot()
    }

    private var currentPane: Pane {
        viewModel.navigationPath.last ?? .root
    }

    @ViewBuilder
    private var sheetSurface: some View {
        VStack(spacing: 0) {
            SettingsHeader(
                title: currentPane.title,
                isRoot: currentPane == .root,
                onBack: { viewModel.popPane() },
                onClose: { close() }
            )
            NavigationStack(path: $viewModel.navigationPath) {
                ScrollView {
                    SettingsRootPane(viewModel: viewModel)
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
        .background(theme.background)
        .clipShape(
            UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 22, topTrailing: 22),
                style: .continuous
            )
        )
        .padding(.top, 40)
        .ignoresSafeArea(edges: .bottom)
        .shadow(color: Color.black.opacity(0.15), radius: 30, x: 0, y: -8)
    }

    @ViewBuilder
    private func paneContent(_ pane: Pane) -> some View {
        switch pane {
        case .root:
            SettingsRootPane(viewModel: viewModel)
        case .models:
            SettingsModelsPane(viewModel: viewModel)
        case .modelDetail(let id):
            SettingsModelDetailPane(viewModel: viewModel, editingId: id)
        case .theme:
            SettingsThemePane(viewModel: viewModel)
        case .prompt:
            SettingsPromptPane(viewModel: viewModel)
        case .verbosity:
            SettingsVerbosityPane(viewModel: viewModel)
        case .appearance:
            SettingsAppearancePane(viewModel: viewModel)
        case .tools:
            SettingsToolsPane(viewModel: viewModel)
        case .compaction:
            SettingsCompactionPane(viewModel: viewModel)
        case .data:
            SettingsDataPane(viewModel: viewModel)
        case .about:
            SettingsAboutPane(viewModel: viewModel)
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
        case .light: return .make(SuperTheme.Identifier.light)
        case .dark: return .make(SuperTheme.Identifier.dark)
        case .sepia: return .make(SuperTheme.Identifier.sepia)
        }
    }
}
