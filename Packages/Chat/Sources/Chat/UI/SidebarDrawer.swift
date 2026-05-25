import Core
import SwiftUI

/// Left-anchored 300pt drawer overlaying the active applet. Hosts the Super
/// wordmark, a New-Chat call-to-action (CTA), the registry-driven applet
/// rail, the chronological chats list (rendered only when Chat is the active
/// applet), and a footer with an identity capsule + Settings button.
///
/// The host is responsible for placing this in a `ZStack` over the active
/// surface and toggling `isPresented`. This view paints its own scrim so the
/// host doesn't have to coordinate dimming.
///
/// **Callback contract**: every action callback (`onSelectConversation`,
/// `onNewChat`, `onOpenSettings`, `onSelectApplet`) is invoked *after* the
/// drawer has already started its dismissal animation. The host can rely on
/// the drawer being in a closing state when its callback fires.
public struct SidebarDrawer: View {
    /// `true` while the drawer is visible (slid in + scrim shown). The
    /// drawer mutates the binding to `false` immediately before each
    /// callback fires; the host can also flip it externally to dismiss.
    @Binding public var isPresented: Bool

    /// Source of `chats` rows + `activeConversationId`. The host owns the
    /// instance and refreshes it on a schedule appropriate for its UI.
    @Bindable public var viewModel: SidebarViewModel

    /// Bundle metadata rendered into the wordmark caption (`v… · personal`).
    public let appInfo: SuperAppInfo

    /// Two-letter initials painted into the 30pt circle in the footer.
    public let userInitials: String

    /// Full display name shown next to the initials in the footer capsule.
    public let userName: String

    /// Applets registered with the shell, in display order. Rendered as a
    /// vertical rail between the New Chat CTA and the CHATS history list.
    /// Driven by the shell's `AppletRegistry`; the drawer itself doesn't
    /// decide which applets exist or in what order. Chat is the *host*
    /// surface — it's not registered as an applet and doesn't appear in
    /// this list.
    public let applets: [any MiniApplet]

    /// Identifier of the currently-active backdrop applet, or `nil` if
    /// no backdrop is active (chat-only surface). The matching rail row
    /// is highlighted with `theme.accentSoft` when non-`nil`.
    public let activeAppletID: String?

    /// Fires when a row in the CHATS list is tapped. The drawer has
    /// already begun closing; the host should swap the active chat.
    public let onSelectConversation: (String) -> Void

    /// Fires when the New Chat CTA is tapped. The drawer has already
    /// begun closing; the host should create a new `ConversationRecord`
    /// and switch to it.
    public let onNewChat: () -> Void

    /// Fires when the Settings gear is tapped. The drawer has already
    /// begun closing; the host should present the Settings sheet.
    public let onOpenSettings: () -> Void

    /// Fires when an applet rail row is tapped. The drawer has already
    /// begun closing; the host should flip the registry's `activeID`.
    public let onSelectApplet: (String) -> Void

    /// Fires when the "See all chats…" overflow row is tapped (only
    /// rendered when `viewModel.hasMoreChats == true`). The drawer
    /// has already begun closing; the host should switch the backdrop
    /// to the Chats applet — which is the see-all surface — and
    /// collapse the chat overlay so the list owns the screen.
    public let onSeeAllChats: () -> Void

    @Environment(\.superTheme) private var theme

    private let drawerWidth: CGFloat = 300

    /// Build a drawer.
    ///
    /// - Parameters:
    ///   - isPresented: Two-way binding controlling visibility.
    ///   - viewModel: Shared sidebar state owner.
    ///   - appInfo: Used for the version caption under the wordmark.
    ///   - userInitials: Painted into the footer initials circle.
    ///   - userName: Displayed next to the initials.
    ///   - applets: Ordered list of registered applets to render in the rail.
    ///   - activeAppletID: Identifier of the active backdrop applet, or
    ///     `nil` if no backdrop is active (chat-only surface).
    ///   - onSelectConversation: Invoked with the tapped conversation id.
    ///   - onNewChat: Invoked when the New Chat CTA is tapped.
    ///   - onOpenSettings: Invoked when the Settings gear is tapped.
    ///   - onSelectApplet: Invoked with the tapped applet's `appletID`.
    ///   - onSeeAllChats: Invoked when the "See all chats…" overflow
    ///     row is tapped — only present when the underlying chats list
    ///     is capped (more than 10 conversations on disk).
    public init(
        isPresented: Binding<Bool>,
        viewModel: SidebarViewModel,
        appInfo: SuperAppInfo,
        userInitials: String,
        userName: String,
        applets: [any MiniApplet],
        activeAppletID: String?,
        onSelectConversation: @escaping (String) -> Void,
        onNewChat: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onSelectApplet: @escaping (String) -> Void,
        onSeeAllChats: @escaping () -> Void
    ) {
        self._isPresented = isPresented
        self.viewModel = viewModel
        self.appInfo = appInfo
        self.userInitials = userInitials
        self.userName = userName
        self.applets = applets
        self.activeAppletID = activeAppletID
        self.onSelectConversation = onSelectConversation
        self.onNewChat = onNewChat
        self.onOpenSettings = onOpenSettings
        self.onSelectApplet = onSelectApplet
        self.onSeeAllChats = onSeeAllChats
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            if isPresented {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .transition(.opacity)
                    .accessibilityHidden(true)

                drawerSurface
                    .frame(width: drawerWidth)
                    .frame(maxHeight: .infinity)
                    .background(theme.sidebar.ignoresSafeArea(edges: .vertical))
                    .shadow(color: Color.black.opacity(0.10), radius: 30, x: 4, y: 0)
                    .transition(.move(edge: .leading))
                    // VoiceOver users can dismiss with the two-finger Z
                    // (escape) gesture since the scrim is hidden.
                    .accessibilityAction(.escape) { close() }
            }
        }
        .animation(.easeOut(duration: 0.22), value: isPresented)
        .accessibilityAddTraits(isPresented ? .isModal : [])
    }

    private func close() {
        isPresented = false
    }

    // MARK: - Surface

    @ViewBuilder
    private var drawerSurface: some View {
        VStack(spacing: 0) {
            wordmarkHeader
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    // New Chat CTA, applet rail, and chat history always
                    // render — chat is the shell's host surface, not a
                    // sidebar-listed applet, so its history is the user's
                    // primary navigation regardless of which applet
                    // backdrop is active.
                    newChatButton

                    ForEach(applets, id: \.appletID) { applet in
                        appletRow(applet)
                    }

                    sectionLabel("Chats")

                    ForEach(viewModel.chats) { chat in
                        ChatRow(
                            chat: chat,
                            isActive: chat.id == viewModel.activeConversationId,
                            onSelect: { onSelectConversation(chat.id) }
                        )
                    }

                    if viewModel.hasMoreChats {
                        SeeAllChatsRow {
                            close()
                            onSeeAllChats()
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 110)
            }
            .scrollIndicators(.hidden)
        }
        .overlay(alignment: .bottom) {
            footer
        }
        .foregroundStyle(theme.ink)
    }

    private var wordmarkHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Super")
                .font(.system(size: 36, weight: .regular, design: .serif))
                .italic()
                .lineLimit(1)
                .foregroundStyle(theme.ink)
            Text("v\(appInfo.version) · personal")
                .font(.system(.caption2, design: .monospaced))
                .tracking(0.3)
                .foregroundStyle(theme.inkFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 60, leading: 24, bottom: 14, trailing: 24))
    }

    private var newChatButton: some View {
        Button(action: {
            close()
            onNewChat()
        }) {
            HStack(spacing: 14) {
                NewChatIcon(size: 20)
                    .foregroundStyle(theme.accentInk)
                Text("New Chat")
                    .font(.system(.body).weight(.medium))
                    .foregroundStyle(theme.accentInk)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.accent)
            )
            .shadow(color: theme.accent.opacity(0.25), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func appletRow(_ applet: any MiniApplet) -> some View {
        let isActive = applet.appletID == activeAppletID
        Button(action: {
            close()
            onSelectApplet(applet.appletID)
        }) {
            HStack(spacing: 14) {
                applet.iconView(size: 20)
                    .foregroundStyle(isActive ? theme.accent : theme.inkSoft)
                Text(applet.displayName)
                    .font(.system(.body).weight(isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? theme.accent : theme.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? theme.accentSoft : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(SidebarPressableRowStyle(theme: theme, cornerRadius: 12, suppressBackground: isActive))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(.caption2).weight(.medium))
            .tracking(1)
            .foregroundStyle(theme.inkFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 20)
            .padding(.bottom, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(theme.accentSoft)
                    Text(userInitials)
                        .font(.system(.caption2).weight(.semibold))
                        .foregroundStyle(theme.accent)
                }
                .frame(width: 30, height: 30)

                Text(userName)
                    .font(.system(.footnote))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(theme.backgroundRaised)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(theme.borderFaint, lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 4)

            Button(action: {
                close()
                onOpenSettings()
            }) {
                SettingsIcon(size: 20)
                    .foregroundStyle(theme.accentInk)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(theme.accent))
                    .shadow(color: Color.black.opacity(0.15), radius: 2, x: 0, y: 2)
                    .shadow(color: Color.black.opacity(0.10), radius: 6, x: 0, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }
}

// MARK: - Chat row

/// One row in the CHATS list. Active row uses `accent` ink + `accentSoft`
/// background; running row gets a leading rotating spinner.
private struct ChatRow: View {
    let chat: SidebarViewModel.ChatItem
    let isActive: Bool
    let onSelect: () -> Void

    @Environment(\.superTheme) private var theme
    /// Row title intentionally does **not** track the chat font-scale
    /// slider — it's drawer chrome, not reading content, so the slider
    /// stays scoped to the message list. `@ScaledMetric` still composes
    /// Dynamic Type on top of the 17pt base so accessibility text-size
    /// preferences continue to apply.
    @ScaledMetric(relativeTo: .subheadline) private var rowTitleBase: CGFloat = 17

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                if chat.running {
                    SpinnerRing()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(theme.accent)
                }
                Text(chat.title)
                    .font(.system(size: rowTitleBase).weight(isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? theme.accent : theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? theme.accentSoft : Color.clear)
            )
        }
        .buttonStyle(SidebarPressableRowStyle(theme: theme, cornerRadius: 10, suppressBackground: isActive))
    }
}

// MARK: - See-all overflow row

/// Footer row in the CHATS section rendered when there are more than
/// `SidebarViewModel.sidebarChatLimit` conversations on disk. Routes to
/// the Chats applet — which is the searchable see-all surface — rather
/// than expanding the list inline.
private struct SeeAllChatsRow: View {
    let onTap: () -> Void

    @Environment(\.superTheme) private var theme
    /// Intentionally does **not** track the chat font-scale slider —
    /// mirrors `ChatRow` above: the drawer is chrome, not reading
    /// content, so the slider stays scoped to the message list.
    /// `@ScaledMetric` still composes Dynamic Type on top of the 15pt
    /// base so accessibility text-size preferences continue to apply.
    @ScaledMetric(relativeTo: .subheadline) private var rowTitleBase: CGFloat = 15

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text("See all chats…")
                    .font(.system(size: rowTitleBase))
                    .foregroundStyle(theme.inkSoft)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.inkMute)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SidebarPressableRowStyle(theme: theme, cornerRadius: 10))
        .accessibilityLabel("See all chats")
    }
}

// MARK: - Pressable row style

/// Mirrors the React `onMouseEnter / onMouseLeave` `--bg-sunken` hover
/// using SwiftUI's `isPressed` configuration. Skips the press state when
/// the row is already painted with the active background — pressing an
/// already-active row shouldn't re-tint underneath.
private struct SidebarPressableRowStyle: ButtonStyle {
    let theme: SuperTheme
    let cornerRadius: CGFloat
    var suppressBackground: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let pressTint = (configuration.isPressed && !suppressBackground)
            ? theme.backgroundSunken
            : Color.clear
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(pressTint)
            )
    }
}

// MARK: - Spinner ring

/// Small rotating arc used as the per-row "in-flight turn" indicator.
/// Ring border is `theme.border`; the leading 90° wedge uses
/// `currentColor` (parent sets `foregroundStyle` to `accent`).
private struct SpinnerRing: View {
    @Environment(\.superTheme) private var theme
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(theme.border, lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .foregroundStyle(.tint)
                .rotationEffect(.degrees(rotation))
        }
        .tint(theme.accent)
        .onAppear { startSpinning() }
    }

    private func startSpinning() {
        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }
}
