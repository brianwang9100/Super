import Core
import SwiftUI

/// Keeps unsaved text locally; the presenter owns persistence and dismissal.
struct NoteEditor: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    enum Mode: Sendable, Equatable {
        case create
        case edit
    }

    let citation: String
    let mode: Mode
    let onSave: (String) -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var text: String
    @State private var showDeleteConfirmation: Bool = false

    @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption2) private var captionSize: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var entrySize: CGFloat = 16

    init(
        citation: String,
        mode: Mode,
        initialText: String = "",
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.citation = citation
        self.mode = mode
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        self._text = State(initialValue: initialText)
    }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // No drag indicator, so use the zero-top-inset nav-bar sizing.
            SheetNavBar(
                title: mode == .edit ? "Edit note" : "New note",
                sizing: .fitsContent,
                onClose: onCancel
            ) {
                saveButton
            }
            Rectangle()
                .fill(theme.borderFaint)
                .frame(height: 0.5)
            caption
            entry
            if mode == .edit {
                deleteSection
            }
        }
        // Add margin below the large sheet's top edge because fitsContent has no nav-bar inset.
        .padding(.top, 14)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                .fill(theme.background)
                .ignoresSafeArea(edges: .bottom)
        }
        .confirmationDialog(
            "Delete this note?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete note", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var saveButton: some View {
        Button {
            onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } label: {
            Image(systemName: "checkmark")
                .font(typography.font(size: 16, weight: .semibold))
                .foregroundStyle(canSave ? theme.accentInk : theme.inkMute)
                .frame(width: 44, height: 44)
                .superGlassCTAButton(in: Circle())
                .opacity(canSave ? 1 : 0.6)
        }
        .buttonStyle(GlassHapticButtonStyle(.primary))
        .disabled(!canSave)
        .accessibilityLabel("Save note")
    }

    private var caption: some View {
        Text("On \(citation)".uppercased())
            .font(typography.font(size: captionSize, weight: .medium, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(theme.inkFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 12)
    }

    private var entry: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Write a note on this passage…")
                    .font(typography.font(size: entrySize))
                    .foregroundStyle(theme.inkFaint)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
                    // The editor owns the spoken label; hide the duplicate placeholder.
                    .accessibilityHidden(true)
            }
            TextEditor(text: $text)
                .font(typography.font(size: entrySize))
                .lineSpacing(4)
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .accessibilityLabel("Note text")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var deleteSection: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(theme.borderFaint)
                .frame(height: 0.5)
            Button {
                showDeleteConfirmation = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(typography.font(size: titleSize, weight: .medium))
                    Text("Delete note")
                        .font(typography.font(size: titleSize, weight: .semibold))
                }
                .foregroundStyle(theme.errorAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(theme.errorBackground)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete note")
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 22)
        }
    }
}
