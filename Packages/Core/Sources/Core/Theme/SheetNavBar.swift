import SwiftUI

/// Match the sheet's detents so the header clears iOS's differently placed grabber.
public enum SheetSizing: Sendable {
    /// Height detents already reserve space below the grabber; no extra header inset.
    case fitsContent

    /// Medium/large detents overlay the grabber on content and need header clearance.
    case expandable

    /// Calibrated on iPhone 17/iOS 26.4 for comparable grabber-to-title spacing across detents.
    public var navBarTopInset: CGFloat {
        switch self {
        case .fitsContent: 0
        case .expandable: 14
        }
    }
}

public struct SheetNavBar<Trailing: View>: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    private let title: String
    private let subtitle: String?
    private let sizing: SheetSizing
    private let onClose: () -> Void
    private let trailing: Trailing

    /// Pass the same sizing to sheetPresentation so header clearance matches the detents.
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
                    // Keep subtitle and title on the same scaling axes so Dynamic Type cannot outgrow the title.
                    Text(subtitle)
                        .font(typography.font(size: 11, weight: .medium, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(theme.inkFaint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)

            // Mirror the close button's footprint to center the title even without a trailing control.
            trailing
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 14)
        .padding(.top, sizing.navBarTopInset)
        .padding(.bottom, 10)
    }
}

public extension SheetNavBar where Trailing == Color {
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
    /// Apply to the sheet root with the header's SheetSizing. fitsContent measures
    /// height; expandable uses medium/large detents. readableBackground keeps content
    /// behind a fitsContent sheet interactive and undimmed. Prefer a slightly large
    /// estimatedHeight to avoid clipping before the first measurement.
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

private struct SheetPresentationModifier: ViewModifier {
    @Environment(\.superTheme) private var theme

    let sizing: SheetSizing
    let readableBackground: Bool
    let estimatedHeight: CGFloat

    @State private var measuredHeight: CGFloat?

    // Height detents include the home-indicator area outside the measured content.
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
