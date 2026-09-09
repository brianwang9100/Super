import Core
import SwiftUI

/// Chat owns chrome and placement; the applet supplies glyphs and actions.
public struct ComposerAccessoryFlank: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let buttons: ComposerAccessoryButtons

    public init(buttons: ComposerAccessoryButtons) {
        self.buttons = buttons
    }

    public var body: some View {
        // Read observable applet state here so visibility updates without republishing closures.
        let buttonsHidden = buttons.shouldHideButtons?() ?? false
        let hasSelection = buttons.selection != nil
        HStack(spacing: 0) {
            button(buttons.leading, hidden: buttonsHidden)
            Spacer(minLength: 8)
            if let selection = buttons.selection {
                SelectionPill(
                    title: selection.title,
                    accessibilityLabel: selection.accessibilityLabel,
                    onAction: selection.onExpand,
                    onClear: selection.onClear,
                    disclosureSystemImage: "chevron.up"
                )
                .transition(.opacity)
            }
            Spacer(minLength: 8)
            button(buttons.trailing, hidden: buttonsHidden)
        }
        .animation(
            SuperMotion.chrome(hiding: !hasSelection, reduceMotion: reduceMotion),
            value: hasSelection
        )
        // Contain accessibility so the shell's row visibility cannot override each control.
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func button(_ descriptor: ComposerAccessoryButton?, hidden: Bool) -> some View {
        if let descriptor {
            Button(action: descriptor.action) {
                Image(systemName: descriptor.systemImage)
                    .font(typography.font(size: 16, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .frame(width: 44, height: 44)
                    .superGlassButton(in: Circle())
            }
            .buttonStyle(GlassHapticButtonStyle(.selection))
            .disabled(!descriptor.isEnabled)
            .opacity(hidden ? 0 : (descriptor.isEnabled ? 1 : 0.35))
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
            .accessibilityLabel(descriptor.accessibilityLabel)
            .animation(
                SuperMotion.chrome(hiding: hidden, reduceMotion: reduceMotion),
                value: hidden
            )
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }
}
