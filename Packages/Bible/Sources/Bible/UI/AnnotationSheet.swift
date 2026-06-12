import Core
import SwiftUI

/// The bottom sheet that shows a target's annotation — one long-form
/// markdown study card.
///
/// Anatomy (top to bottom):
///
/// - **Nav bar** — the scripture citation (e.g. `"Romans 8:28-30"`) plus
///   a small uppercase "Annotation" caption and a kebab-overflow menu
///   carrying "Regenerate", "Add to chat", and the destructive "Delete".
/// - **Body** — a vertical scroll hosting the single `AnnotationBlock`
///   (title / verse text / markdown summary / provenance), or an
///   empty/generating/error state when there is no card.
///
/// The sheet is stateless beyond the local delete-confirmation gate: it
/// owns no GRDB-bound `@Query`, no view model, no event-bus publish. Its
/// parent (`AnnotationSheetContainer`) supplies the card payload and
/// closes the callbacks.
///
/// Scripture citations inside the rendered summary arrive as
/// `super://bible/...` links (the shared renderer linkifies them); the
/// sheet intercepts those taps via `OpenURLAction` and routes them to
/// `onOpenLink` — non-Bible URLs fall through to the system.
struct AnnotationSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    /// The one card to render — a plain display struct (no
    /// `Identifiable`: the redesign deliberately removed the multi-card
    /// list, so there is nothing to diff by id). The parent does the
    /// record→display projection (citation title, verse-text lookup,
    /// provenance formatting) before constructing it.
    struct Card: Sendable, Equatable {
        /// Citation title, e.g. `"Romans 8:28-30"`.
        let title: String
        /// Plain verse text for verse-range targets; `nil` for
        /// chapter/book targets or when the text failed to load.
        let verseText: String?
        /// Long-form markdown study summary.
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

    /// Display citation in the nav bar, e.g. `"Romans 8:28-30"`.
    let citation: String
    /// The annotation to render, `nil` when none exists yet. (Kept as a
    /// single optional rather than an array: `replace` semantics make
    /// one-row-per-target the steady state, and the container renders
    /// `records.first` defensively.)
    let card: Card?
    /// `true` while a generation request is in flight.
    ///
    /// **Contract**: when `true`, the generating state is shown
    /// *regardless* of whether `card` is populated — a regenerate hides
    /// the stale card behind the spinner until the fresh row lands. On
    /// failure the parent clears the running status, so the previous
    /// card reappears (a regenerate never destroys the old row up
    /// front). `errorMessage` is only consulted when `card == nil` AND
    /// `isGenerating` is `false`.
    let isGenerating: Bool
    /// Short human-readable failure reason from a terminal
    /// `BibleAnnotateResult.failure`. When non-nil, the empty state
    /// renders an error variant with this message + a "Try again"
    /// button instead of the generating or empty layouts. Non-nil only
    /// while `card == nil` — if a row landed despite the failure
    /// (rare race: tool wrote the row and *then* the LLM emitted an
    /// error), the card takes precedence and the error is suppressed.
    let errorMessage: String?
    /// Extra bottom padding so the card clears the shell's minimized
    /// chat pill; `0` in standalone (snapshot) contexts.
    let bottomInset: CGFloat
    /// Dismisses the sheet from the nav bar's leading close button.
    let onClose: () -> Void
    let onRegenerate: () -> Void
    /// "Add to chat" on the kebab. Only reachable when a card exists.
    let onAddToChat: () -> Void
    /// Confirmed delete from the kebab's destructive item.
    let onDelete: () -> Void
    /// A `super://bible/...` citation link inside the summary was
    /// tapped. The parent navigates the reader.
    let onOpenLink: (BibleDeepLink) -> Void
    /// Tap on the empty-state retry button. Fires only when
    /// `errorMessage` is non-nil; ignored on the empty and generating
    /// branches.
    let onRetry: () -> Void

    /// Local gate for the destructive-delete confirmation dialog. The
    /// kebab's "Delete" sets it true; the dialog's confirm then fires
    /// `onDelete`. Per iOS HIG, non-reversible destructive actions in
    /// menus get a confirmation step.
    @State private var showDeleteConfirmation: Bool = false

    /// Parameters without defaults come first, per the root AGENTS.md
    /// "Default parameter values" rule — the required content and
    /// callback set up front, the optional `isGenerating` /
    /// `errorMessage` / `bottomInset` last.
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

    /// `.medium`/`.large` list sheet — same detents the book picker uses.
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

    /// Kebab overflow carrying the sheet actions, hosted in the nav bar's
    /// trailing slot. Theme-tinted glass to match the leading close button and
    /// the other sheets' trailing controls. "Add to chat" and "Delete" only
    /// appear when a card exists — on the empty/generating/error layouts the
    /// kebab carries just "Regenerate".
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
            // A regenerate is in flight: hide the stale card behind the
            // generating state so the user sees fresh work underway, not
            // the about-to-be-replaced previous annotation. Wins over
            // `card` — see the `isGenerating` contract above.
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
            // Font-scale projection + citation-link routing for the
            // rendered markdown — see `bibleMarkdownRendering`.
            .bibleMarkdownRendering(openLink: onOpenLink)
        } else {
            // Expand to fill the sheet body so the empty / error cluster
            // centers in the detent instead of hugging the divider with
            // dead space below. The presentation detent (or the snapshot
            // test's `.frame(height:)`) is the bound that resolves
            // `.infinity` — no unbounded-parent layout warning fires in
            // either context.
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Spinner-bubble cluster shown while a generation request is in
    /// flight, including a regenerate over an already-populated card.
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

    /// Render the terminal-failure variant: the empty bubble, the
    /// short failure reason, and a primary "Try again" button bound to
    /// `onRetry`. The failure copy is intentionally short — the
    /// dispatcher's message text already names the underlying cause
    /// (no key, model didn't call tool, provider error), so the sheet
    /// just surfaces it verbatim above the retry affordance.
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
