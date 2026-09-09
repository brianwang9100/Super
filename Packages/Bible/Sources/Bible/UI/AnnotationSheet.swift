import Core
import SwiftUI

/// The container supplies live records and mutations. Bible citation links route
/// through onOpenLink; other URLs retain system handling.
struct AnnotationSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    struct Card: Sendable, Equatable {
        let title: String
        /// Nil for book/chapter targets or unavailable verse text.
        let verseText: String?
        let summary: String
        let provenance: String

        init(
            title: String,
            verseText: String?,
            summary: String,
            provenance: String
        ) {
            self.title = title
            self.verseText = verseText
            self.summary = summary
            self.provenance = provenance
        }
    }

    let citation: String
    let card: Card?
    /// Generation hides even a populated card. After failure, retained content reappears;
    /// errorMessage is considered only without a card or active generation.
    let isGenerating: Bool
    let errorMessage: String?
    /// Reserve for the minimized chat pill; zero in standalone contexts.
    let bottomInset: CGFloat
    let onClose: () -> Void
    let onRegenerate: () -> Void
    let onAddToChat: () -> Void
    /// Called after delete confirmation.
    let onDelete: () -> Void
    let onOpenLink: (BibleDeepLink) -> Void
    let onRetry: () -> Void

    @State private var showDeleteConfirmation: Bool = false

    init(
        citation: String,
        card: Card?,
        onClose: @escaping () -> Void,
        onRegenerate: @escaping () -> Void,
        onAddToChat: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onOpenLink: @escaping (BibleDeepLink) -> Void,
        onRetry: @escaping () -> Void = {},
        isGenerating: Bool = false,
        errorMessage: String? = nil,
        bottomInset: CGFloat = 0
    ) {
        self.citation = citation
        self.card = card
        self.isGenerating = isGenerating
        self.errorMessage = errorMessage
        self.bottomInset = bottomInset
        self.onClose = onClose
        self.onRegenerate = onRegenerate
        self.onAddToChat = onAddToChat
        self.onDelete = onDelete
        self.onOpenLink = onOpenLink
        self.onRetry = onRetry
    }

    private let sizing = SheetSizing.expandable

    var body: some View {
        VStack(spacing: 0) {
            SheetNavBar(
                title: citation,
                subtitle: "ANNOTATION",
                sizing: sizing,
                onClose: onClose
            ) {
                overflowMenu
            }
            Rectangle()
                .fill(theme.borderFaint)
                .frame(height: 0.5)
            content
        }
        .sheetPresentation(sizing)
        .confirmationDialog(
            "Delete this annotation?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete annotation", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The annotation will be permanently removed.")
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button(action: onRegenerate) {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
            if card != nil {
                Button(action: onAddToChat) {
                    Label("Add to chat", systemImage: "paperplane")
                }
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

    @ViewBuilder
    private var content: some View {
        if isGenerating {
            generatingState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let card {
            ScrollView {
                AnnotationBlock(
                    title: card.title,
                    verseText: card.verseText,
                    summary: card.summary,
                    provenance: card.provenance
                )
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 24 + bottomInset)
            }
            .bibleMarkdownRendering(openLink: onOpenLink)
        } else {
            // Fill the bounded detent so empty/error content stays centered.
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var generatingState: some View {
        VStack(spacing: 10) {
            AnnotationBubble(state: .generating, size: 28)
            Text("Generating annotation…")
                .font(typography.font(size: 14))
                .foregroundStyle(theme.inkSoft)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private var emptyState: some View {
        if let errorMessage {
            errorState(message: errorMessage)
        } else {
            VStack(spacing: 10) {
                AnnotationBubble(state: .empty, size: 28)
                Text("No annotation yet. Tap to generate.")
                    .font(typography.font(size: 14))
                    .foregroundStyle(theme.inkSoft)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 40)
        }
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 12) {
            AnnotationBubble(state: .empty, size: 28)
            Text(message)
                .font(typography.font(size: 14))
                .foregroundStyle(theme.inkSoft)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Button(action: onRetry) {
                Text("Try again")
                    .font(typography.font(size: 14, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(theme.backgroundSunken)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Try again")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 40)
    }
}
