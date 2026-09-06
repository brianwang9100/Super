import Core
import SwiftUI

/// The leading / trailing hovering accessory buttons for the chat composer,
/// rendered with Chat's circular Liquid Glass chrome (matching the composer's
/// own 44pt controls). Generic: the buttons come from a ``ComposerAccessoryButtons``
/// descriptor pair an applet publishes through ``ComposerAccessoryStore`` — Chat
/// owns the chrome and placement, the applet owns the glyphs and actions.
///
/// Pure layout: the host (the shell's composer-accessory layer) supplies the
/// vertical anchor, opacity, and edge padding; this view lays out the edge
/// buttons around an optional selection pill. An inert placeholder on a
/// missing edge keeps the selection centered and the other edge pinned.
public struct ComposerAccessoryFlank: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    private let buttons: ComposerAccessoryButtons

    public init(buttons: ComposerAccessoryButtons) {
        self.buttons = buttons
    }

    public var body: some View {
        HStack(spacing: 0) {
            button(buttons.leading)
            Spacer(minLength: 8)
            if let selection = buttons.selection {
                SelectionPill(
                    title: selection.title,
                    accessibilityLabel: selection.accessibilityLabel,
                    onAction: selection.onExpand,
                    onClear: selection.onClear,
                    disclosureSystemImage: selection.isExpanded ? nil : "chevron.up"
                )
            }
            Spacer(minLength: 8)
            button(buttons.trailing)
        }
    }

    @ViewBuilder
    private func button(_ descriptor: ComposerAccessoryButton?) -> some View {
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
            .opacity(descriptor.isEnabled ? 1 : 0.35)
            .accessibilityLabel(descriptor.accessibilityLabel)
        } else {
            // Hold the opposite edge in place when only one side has a button.
            Color.clear.frame(width: 44, height: 44)
        }
    }
}
