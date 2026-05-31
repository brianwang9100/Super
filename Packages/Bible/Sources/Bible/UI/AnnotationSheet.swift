import Core
import SwiftUI

/// The bottom sheet that shows a target's annotation cards.
///
/// Anatomy (top to bottom):
///
/// - **Drag handle** — the standard 36×4 capsule reused by the
///   translation + book sheets.
/// - **Header** — the scripture citation (e.g. `"Romans 8:28-30"`) plus
///   a small uppercase "Annotations" caption and a kebab-overflow menu
///   carrying "Regenerate" and "Add all to chat".
/// - **Body** — a vertical scroll of `AnnotationBlock` rows, or an
///   empty/generating state when `cards.isEmpty`.
///
/// The sheet is stateless: it owns no GRDB-bound `@Query`, no view
/// model, no event-bus publish. Its parent supplies the card payload
/// and closes the eight callbacks. PR 3 wires the parent (an
/// `AnnotationSheetViewModel`) into the live reactive query, the
/// `bible.annotate` tool, the event bus, and the chapter navigator.
struct AnnotationSheet: View {
    @Environment(\.superTheme) private var theme

    /// One card to render. The `body` carries the same shape
    /// `AnnotationBlock` consumes; the parent does any markdown
    /// pre-formatting / citation parsing before constructing the card.
    struct Card: Sendable, Identifiable, Equatable {
        let id: String
        let title: String
        let content: AnnotationBlock.Content
        let provenance: String

        init(id: String, title: String, content: AnnotationBlock.Content, provenance: String) {
            self.id = id
            self.title = title
            self.content = content
            self.provenance = provenance
        }
    }

    /// Display citation in the header, e.g. `"Romans 8:28-30"`.
    let citation: String
    let cards: [Card]
    /// `true` while a generation request is in flight.
    ///
    /// **Contract**: this flag is only consulted when `cards.isEmpty`
    /// AND `errorMessage` is `nil`. When `cards` is non-empty the flag
    /// is silently a no-op — the existing cards still render with no
    /// loading indicator. PR 4's `AnnotationSheetContainer` clears
    /// `cards` first when retry kicks off (so the spinner-state empty
    /// view is visible), then writes the freshly-produced rows once
    /// the `bible.annotate` call returns.
    let isGenerating: Bool
    /// Short human-readable failure reason from a terminal
    /// `BibleAnnotateResult.failure`. When non-nil, the empty state
    /// renders an error variant with this message + a "Try again"
    /// button instead of the generating or empty layouts. Non-nil only
    /// while `cards.isEmpty` — if rows landed despite the failure
    /// (rare race: tool wrote rows and *then* the LLM emitted an
    /// error), the cards take precedence and the error is suppressed.
    let errorMessage: String?
    /// Extra bottom padding so the last card clears the shell's
    /// minimized chat pill; `0` in standalone (snapshot) contexts.
    let bottomInset: CGFloat
    let onRegenerate: () -> Void
    let onAddAllToChat: () -> Void
    let onClose: () -> Void
    let onCardAddToChat: (Card.ID) -> Void
    let onCardDelete: (Card.ID) -> Void
    let onOpenReference: (BibleCitationParser.ParsedCitation) -> Void
    /// Tap on the empty-state retry button. Fires only when
    /// `errorMessage` is non-nil; ignored on the empty and generating
    /// branches.
    let onRetry: () -> Void

    /// Parameters without defaults come first, per the root AGENTS.md
    /// "Default parameter values" rule — the required content and
    /// callback set up front, the optional `isGenerating` /
    /// `errorMessage` / `bottomInset` last.
    init(
        citation: String,
        cards: [Card],
        onRegenerate: @escaping () -> Void,
        onAddAllToChat: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onCardAddToChat: @escaping (Card.ID) -> Void,
        onCardDelete: @escaping (Card.ID) -> Void,
        onOpenReference: @escaping (BibleCitationParser.ParsedCitation) -> Void,
        onRetry: @escaping () -> Void = {},
        isGenerating: Bool = false,
        errorMessage: String? = nil,
        bottomInset: CGFloat = 0
    ) {
        self.citation = citation
        self.cards = cards
        self.isGenerating = isGenerating
        self.errorMessage = errorMessage
        self.bottomInset = bottomInset
        self.onRegenerate = onRegenerate
        self.onAddAllToChat = onAddAllToChat
        self.onClose = onClose
        self.onCardAddToChat = onCardAddToChat
        self.onCardDelete = onCardDelete
        self.onOpenReference = onOpenReference
        self.onRetry = onRetry
    }

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            Rectangle()
                .fill(theme.borderFaint)
                .frame(height: 0.5)
            cardList
        }
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                .fill(theme.background)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var grabber: some View {
        Capsule()
            .fill(theme.inkFaint)
            .frame(width: 36, height: 4)
            .opacity(0.6)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(citation)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.ink)
            Text("ANNOTATIONS")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(theme.inkFaint)
            Spacer()
            Menu {
                Button(action: onRegenerate) {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                Button(action: onAddAllToChat) {
                    Label("Add all to chat", systemImage: "paperplane")
                }
                Divider()
                // `Close` is not `.cancel`-roled: `.cancel` is a
                // `.confirmationDialog` / `.alert` convention; inside a
                // `Menu` it has no guaranteed dismiss-first behavior.
                Button("Close", action: onClose)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.inkSoft)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(theme.backgroundSunken))
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Sheet actions")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var cardList: some View {
        if cards.isEmpty {
            // Expand to fill the sheet body so the empty / generating /
            // error cluster centers in the detent instead of hugging
            // the divider with dead space below. The presentation
            // detent (or the snapshot test's `.frame(height:)`) is the
            // bound that resolves `.infinity` — no unbounded-parent
            // layout warning fires in either context.
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(cards) { card in
                        AnnotationBlock(
                            title: card.title,
                            content: card.content,
                            provenance: card.provenance,
                            onAddToChat: { onCardAddToChat(card.id) },
                            onDelete: { onCardDelete(card.id) },
                            onOpenReference: onOpenReference
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 24 + bottomInset)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let errorMessage {
            errorState(message: errorMessage)
        } else {
            VStack(spacing: 10) {
                AnnotationBubble(state: isGenerating ? .generating : .empty, size: 28)
                Text(isGenerating
                     ? "Generating annotations…"
                     : "No annotations yet. Tap to generate.")
                    .font(.system(size: 14))
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
    /// `onRetry`. Spec §5's failure copy is intentionally short — the
    /// dispatcher's message text already names the underlying cause
    /// (no key, model didn't call tool, provider error), so the sheet
    /// just surfaces it verbatim above the retry affordance.
    private func errorState(message: String) -> some View {
        VStack(spacing: 12) {
            AnnotationBubble(state: .empty, size: 28)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(theme.inkSoft)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Button(action: onRetry) {
                Text("Try again")
                    .font(.system(size: 14, weight: .medium))
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
