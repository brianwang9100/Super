import Core
import SwiftUI

/// Composer-free annotation transcript, with the same response UI as Chat.
struct AnnotationSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.pasteboardClient) private var pasteboard

    /// Persisted response projection supplied by the query container.
    struct Card: Sendable, Equatable {
        let title: String
        let verseText: String?
        let summary: String
        let provenance: String
    }

    let citation: String
    let card: Card?
    let onClose: () -> Void
    let onRegenerate: () -> Void
    let onAddToChat: () -> Void
    let onDelete: () -> Void
    let onOpenLink: (BibleDeepLink) -> Void
    var onRetry: () -> Void = {}
    var isGenerating = false
    var errorMessage: String?
    var bottomInset: CGFloat = 0
    var verseText: String?
    var responseText: String?
    var isShowingDraft = false
    var treatAsPartial = false
    var onReturnToSaved: (() -> Void)?

    @State private var showDeleteConfirmation = false
    @State private var isCopied = false
    private let sizing = SheetSizing.expandable

    private var showsSavedResponse: Bool { card != nil && !isGenerating && !isShowingDraft }
    private var text: String { responseText ?? (isGenerating ? "" : card?.summary ?? "") }

    var body: some View {
        VStack(spacing: 0) {
            SheetNavBar(title: citation, subtitle: "ANNOTATION", sizing: sizing, onClose: onClose) {
                overflowMenu
            }
            Rectangle().fill(theme.borderFaint).frame(height: 0.5)
            transcript
        }
        .sheetPresentation(sizing)
        .onChange(of: text) { _, _ in isCopied = false }
        .confirmationDialog("Delete this annotation?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete annotation", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The annotation will be permanently removed.")
        }
    }

    // One scroll identity for waiting, streaming, saved, and interrupted states.
    private var transcript: some View {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    AnnotationBlock(
                        title: "",
                        verseText: verseText ?? card?.verseText,
                        summary: text,
                        provenance: showsSavedResponse ? card?.provenance ?? "" : "",
                        treatAsPartial: treatAsPartial || isGenerating,
                        isWorking: isGenerating,
                        onCopy: showsSavedResponse ? { copy() } : nil,
                        onRegenerate: showsSavedResponse ? onRegenerate : nil,
                        isCopied: isCopied
                    )
                    if let errorMessage, !isGenerating {
                        failure(message: errorMessage)
                    } else if text.isEmpty && !isGenerating && !isShowingDraft {
                        Button("Generate annotation", action: onRegenerate)
                            .font(typography.font(size: 14, weight: .medium))
                            .foregroundStyle(theme.inkSoft)
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 24 + bottomInset)
            }
            .bibleMarkdownRendering(openLink: onOpenLink)
    }

    private func copy() {
        pasteboard.copy(text)
        isCopied = true
        AccessibilityNotification.Announcement("Annotation copied").post()
    }

    private var overflowMenu: some View {
        Menu {
            Button(action: onRegenerate) {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
            .disabled(isGenerating || isShowingDraft)
            if showsSavedResponse {
                Button(action: onAddToChat) { Label("Add to chat", systemImage: "paperplane") }
                Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                    Label("Delete", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(typography.font(size: 16, weight: .medium))
                .foregroundStyle(theme.ink)
                .frame(width: 44, height: 44)
                .superGlassButton(in: Circle())
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Sheet actions")
    }

    private func failure(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(typography.font(size: 14))
                .foregroundStyle(theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { retryActions }
                VStack(alignment: .leading, spacing: 12) { retryActions }
            }
            .font(typography.font(size: 14, weight: .medium))
            .foregroundStyle(theme.ink)
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var retryActions: some View {
        Button("Try again", action: onRetry)
        if let onReturnToSaved {
            Button("Show saved annotation", action: onReturnToSaved)
        }
    }
}
