import Core
import SwiftUI

/// Start dismissal before invoking action callbacks; the host can assume the drawer is closing.
public struct SidebarDrawer: View {
    @Binding public var isPresented: Bool

    @Bindable public var viewModel: SidebarViewModel

    public let appInfo: SuperAppInfo

    public let applets: [any MiniApplet]

    public let activeAppletID: String?

    public let onSelectConversation: (String) -> Void

    public let onNewChat: () -> Void

    public let onOpenSettings: () -> Void

    public let onSelectApplet: (String) -> Void

    public let onSeeAllChats: () -> Void

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.hapticsEngine) private var hapticsEngine
    /// System chrome combines ScaledMetric for Dynamic Type with typography.font for app scaling.
    @ScaledMetric(relativeTo: .body) private var navLabelSize: CGFloat = 17
    @ScaledMetric(relativeTo: .caption2) private var sectionLabelSize: CGFloat = 11

    private let drawerWidth: CGFloat = 300

    public init(
        isPresented: Binding<Bool>,
        viewModel: SidebarViewModel,
        appInfo: SuperAppInfo,
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
                    // The hidden scrim needs an accessible dismissal alternative.
                    .accessibilityAction(.escape) { close() }
            }
        }
        .animation(.easeOut(duration: 0.22), value: isPresented)
        .accessibilityAddTraits(isPresented ? .isModal : [])
    }

    private func close() {
        isPresented = false
    }

    @ViewBuilder
    private var drawerSurface: some View {
        VStack(spacing: 0) {
            wordmarkHeader
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    newChatButton

                    ForEach(applets, id: \.appletID) { applet in
                        appletRow(applet)
                    }

                    sectionLabel("Chats")

                    ForEach(viewModel.chats) { chat in
                        ChatRow(
                            chat: chat,
                            isActive: chat.id == viewModel.activeConversationId,
                            onSelect: {
                                hapticsEngine.play(.selection)
                                onSelectConversation(chat.id)
                            }
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
            // The wordmark tracks app font scale but not Dynamic Type; the version tracks both.
            Text(appInfo.bundleName)
                .font(typography.display(36, relativeTo: nil))
                .italic()
                .lineLimit(1)
                .foregroundStyle(theme.ink)
            Text("v\(appInfo.version) · personal")
                .font(typography.mono(11, relativeTo: .caption2))
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
                    .font(typography.font(size: navLabelSize, weight: .medium))
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
        .buttonStyle(GlassHapticButtonStyle(.primary))
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func appletRow(_ applet: any MiniApplet) -> some View {
        let isActive = applet.appletID == activeAppletID
        Button(action: {
            hapticsEngine.play(.selection)
            close()
            onSelectApplet(applet.appletID)
        }) {
            HStack(spacing: 14) {
                applet.iconView(size: 20)
                    .foregroundStyle(isActive ? theme.accent : theme.inkSoft)
                Text(applet.displayName)
                    .font(typography.font(size: navLabelSize, weight: isActive ? .medium : .regular))
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
            .font(typography.font(size: sectionLabelSize, weight: .medium))
            .tracking(1)
            .foregroundStyle(theme.inkFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 20)
            .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button(action: {
                close()
                onOpenSettings()
            }) {
                Image(dsIcon: .settings)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(theme.ink)
                    .frame(width: 44, height: 44)
                    .superGlassButton(in: Circle())
            }
            .buttonStyle(GlassHapticButtonStyle(.selection))
            .accessibilityLabel("Settings")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }
}

private struct ChatRow: View {
    let chat: SidebarViewModel.ChatItem
    let isActive: Bool
    let onSelect: () -> Void

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @ScaledMetric(relativeTo: .body) private var rowTitleBase: CGFloat = 17

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                if chat.running {
                    SpinnerRing()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(theme.accent)
                }
                Text(chat.title)
                    .font(typography.font(size: rowTitleBase, weight: isActive ? .medium : .regular))
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

private struct SeeAllChatsRow: View {
    let onTap: () -> Void

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @ScaledMetric(relativeTo: .subheadline) private var rowTitleBase: CGFloat = 15
    @ScaledMetric(relativeTo: .caption2) private var chevronSize: CGFloat = 11

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text("See all chats…")
                    .font(typography.font(size: rowTitleBase))
                    .foregroundStyle(theme.inkSoft)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(typography.font(size: chevronSize, weight: .medium))
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
