import SwiftUI

/// How a presented sheet sizes itself. Determines the nav-bar's top clearance
/// for the system drag indicator, which iOS positions differently per detent
/// kind — so picking the case that matches a sheet's `presentationDetents` is
/// all that's needed; the spacing follows. **No sheet should hand-tune a top
/// margin** — choose a `SheetSizing` instead.
public enum SheetSizing: Sendable {
    /// Sizes to its own content, presented with a `.height(_:)` detent. iOS
    /// reserves a top safe-area *below* the grabber for content-height sheets,
    /// so the nav bar adds no extra top inset (it would stack on top and read
    /// as too much space). Used by the verse-action, narration, and
    /// translation sheets.
    case fitsContent

    /// An expandable list sheet presented with `.medium` / `.large` detents.
    /// iOS draws the grabber *over* the content's top edge here, so the nav bar
    /// adds clearance to sit clear of it. Used by the book picker.
    case expandable

    /// Top padding the nav bar applies above itself for this sizing. Measured
    /// on-device (iPhone 17 / iOS 26.4): `.fitsContent` nets ~9pt drag-pill →
    /// title and `.expandable` ~7pt, which read as the same spacing.
    public var navBarTopInset: CGFloat {
        switch self {
        case .fitsContent: 0
        case .expandable: 14
        }
    }
}

/// The shared sheet header: a 44pt circular Liquid Glass close (`X`) button on
/// the leading edge, a centered semibold title, and a balancing trailing slot.
/// Gives every bottom sheet (book picker, translation picker, verse actions,
/// narration transport) one consistent nav-bar so they stop reading as four
/// bespoke headers.
///
/// The trailing slot is a fixed 44pt box that mirrors the close button's
/// footprint, so the title stays optically centered even when nothing is in it.
/// Sheets that need a trailing control (narration's Stop) pass it via the
/// `trailing` builder; the rest use the no-trailing convenience init, which
/// fills the slot with an invisible spacer.
///
/// The close button is the only glass element here — the sheet body keeps its
/// own solid `theme.background`, so the header sits flat on that surface rather
/// than introducing a second material.
public struct SheetNavBar<Trailing: View>: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    private let title: String
    private let subtitle: String?
    private let sizing: SheetSizing
    private let onClose: () -> Void
    private let trailing: Trailing

    /// - Parameters:
    ///   - subtitle: an optional small caption rendered under the title — used
    ///     by the annotation ("ANNOTATIONS") and note-list ("{n} Notes") sheets
    ///     to keep the secondary label their bespoke headers carried. `nil`
    ///     renders the title alone.
    ///   - sizing: the sheet's detent kind. Drives the top clearance for the
    ///     system drag indicator so no caller tunes a margin by hand — see
    ///     ``SheetSizing``. Defaults to `.expandable`.
    public init(
        title: String,
        subtitle: String? = nil,
        sizing: SheetSizing = .expandable,
        onClose: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.sizing = sizing
        self.onClose = onClose
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 0) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(typography.font(size: 16, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 44, height: 44)
                    .superGlassButton(in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            VStack(spacing: 2) {
                Text(title)
                    .font(typography.font(.body, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    // Small mono caption matching the tracked, faint style the
                    // annotation / note-list headers used before they unified
                    // behind this bar. Like the title, it tracks the app
                    // font-scale slider but stays inert to OS Dynamic Type
                    // (`typography.font(size:)`, not `@ScaledMetric`).
                    //
                    // Deliberate tradeoff: `NoteListSheet`'s old "{n} Notes"
                    // count used `@ScaledMetric(relativeTo: .caption2)` and so
                    // grew with OS Dynamic Type. Unifying it here drops that —
                    // by design, so the caption stays visually subordinate to a
                    // title that is itself OS-DT-inert (a subtitle that scaled
                    // with OS DT would outgrow the title above it at XXXL). Both
                    // axes still compose via the slider, which scales the whole
                    // bar together.
                    Text(subtitle)
                        .font(typography.font(size: 11, weight: .medium, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(theme.inkFaint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)

            // Fixed 44pt box mirroring the close button so the centered title
            // is balanced; an empty slot renders an invisible spacer.
            trailing
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 14)
        // Top clearance for the system drag indicator (derived from `sizing`)
        // + bottom gap to the content. Owned here so every sheet gets
        // consistent spacing regardless of its own content padding.
        .padding(.top, sizing.navBarTopInset)
        .padding(.bottom, 10)
    }
}

public extension SheetNavBar where Trailing == Color {
    /// Header with no trailing control — the slot becomes an invisible 44pt
    /// spacer so the title stays centered against the leading close button.
    init(
        title: String,
        subtitle: String? = nil,
        sizing: SheetSizing = .expandable,
        onClose: @escaping () -> Void
    ) {
        self.init(title: title, subtitle: subtitle, sizing: sizing, onClose: onClose) { Color.clear }
    }
}

public extension View {
    /// Standard presentation for a `SheetNavBar`-headed sheet — detents, the
    /// system drag indicator, and the themed background — all derived from the
    /// same ``SheetSizing`` the nav bar uses. Apply it to the sheet's root view
    /// so a sheet declares its sizing **once**: the nav-bar top inset and the
    /// detents can no longer drift apart, and no call site hand-assembles the
    /// presentation modifiers.
    ///
    /// - Parameters:
    ///   - sizing: `.fitsContent` measures the view's own height for a
    ///     `.height(_:)` detent; `.expandable` uses `.medium`/`.large`.
    ///   - readableBackground: keep the content *behind* the sheet interactive
    ///     and undimmed (only meaningful for `.fitsContent`) — used by the
    ///     reader's action / narration cards so the page stays readable.
    ///   - estimatedHeight: first-paint height for a `.fitsContent` sheet before
    ///     its real height is measured; prefer slightly large so the sheet
    ///     contracts to fit rather than clipping for a frame.
    func sheetPresentation(
        _ sizing: SheetSizing,
        readableBackground: Bool = false,
        estimatedHeight: CGFloat = 320
    ) -> some View {
        modifier(SheetPresentationModifier(
            sizing: sizing,
            readableBackground: readableBackground,
            estimatedHeight: estimatedHeight
        ))
    }
}

/// Applies the detents / drag indicator / background that match a
/// ``SheetSizing``. For `.fitsContent` it measures the content's own height and
/// feeds it to a `.height(_:)` detent (plus a home-indicator allowance), so the
/// sheet sizes to its content without the host tracking height state.
private struct SheetPresentationModifier: ViewModifier {
    @Environment(\.superTheme) private var theme

    let sizing: SheetSizing
    let readableBackground: Bool
    let estimatedHeight: CGFloat

    /// `nil` until the first geometry read; `estimatedHeight` stands in so the
    /// first paint is close before the real height snaps it.
    @State private var measuredHeight: CGFloat?

    /// Room below the measured content for the home-indicator safe area;
    /// `.height(_:)` detents specify the whole sheet height.
    private static let bottomSafeAreaAllowance: CGFloat = 34

    func body(content: Content) -> some View {
        switch sizing {
        case .expandable:
            content
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.background)
        case .fitsContent:
            let detent = (measuredHeight ?? estimatedHeight) + Self.bottomSafeAreaAllowance
            content
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measuredHeight = $0 }
                .presentationDetents([.height(detent)])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(
                    readableBackground ? .enabled(upThrough: .height(detent)) : .automatic
                )
                .presentationBackground(theme.background)
        }
    }
}
