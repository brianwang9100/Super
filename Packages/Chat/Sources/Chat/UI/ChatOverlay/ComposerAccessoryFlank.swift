import Core
import SwiftUI

/// The leading / trailing hovering accessory buttons for the chat composer,
/// rendered with Chat's circular Liquid Glass chrome (matching the composer's
/// own 44pt controls). Generic: the buttons come from a ``ComposerAccessoryButtons``
/// descriptor pair an applet publishes through ``ComposerAccessoryStore`` — Chat
/// owns the chrome and placement, the applet owns the glyphs and actions.
///
/// Pure layout: the host (the shell's composer-accessory layer) supplies the
/// vertical anchor, whole-row opacity, and edge padding; this view owns the
/// independent edge and selection fades. An inert placeholder on a
/// missing edge keeps the selection centered and the other edge pinned.
public struct ComposerAccessoryFlank: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let buttons: ComposerAccessoryButtons

    public init(buttons: ComposerAccessoryButtons) {
        self.buttons = buttons
    }

    public var body: some View {
        // Read the applet's observable state here so footer visibility updates
        // the edges without republishing the selection or its action closures.
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
        // Override any incoming sheet transaction only when selection mode
        // changes. Editing the citation keeps the existing pill in place.
        .animation(
            SuperMotion.chrome(hiding: !hasSelection, reduceMotion: reduceMotion),
            value: hasSelection
        )
        // Keep the shell's whole-row accessibility visibility on a container
        // so it doesn't override the individual controls' hidden state.
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
            // Mirrors the prior in-nav-bar chevron dim for the disabled
            // (canon-end) state.
            .opacity(hidden ? 0 : (descriptor.isEnabled ? 1 : 0.35))
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
            .accessibilityLabel(descriptor.accessibilityLabel)
            .animation(
                SuperMotion.chrome(hiding: hidden, reduceMotion: reduceMotion),
                value: hidden
            )
        } else {
            // Hold the opposite edge in place when only one side has a button.
            Color.clear.frame(width: 44, height: 44)
        }
    }
}
