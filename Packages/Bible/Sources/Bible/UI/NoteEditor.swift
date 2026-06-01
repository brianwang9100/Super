import Core
import SwiftUI

/// The create / edit modal for a single note.
///
/// Anatomy, per `notes/sheet.jsx`:
///
/// - **Drag handle**, then a three-slot toolbar: a circular **✕ Cancel**
///   (sunken), the centered title ("New note" / "Edit note"), and a
///   circular **✓ Save** (accent; disabled + dimmed while the body is
///   blank).
/// - A mono **"ON {citation}"** caption.
/// - A large free-text entry area with a placeholder on create.
/// - **Edit mode only**: an error-tinted **Delete note** button that
///   raises a destructive `.confirmationDialog` (the same idiomatic
///   confirmation `AnnotationBlock` uses — system chrome, not a bespoke
///   sheet).
///
/// The editor owns the in-progress `text` as local `@State` until Save,
/// then hands it back through `onSave`. Cancel and Delete route through
/// their own callbacks. The presenter (PR3) supplies the range citation,
/// the initial text (empty on create, the note body on edit), and wires
/// the callbacks to the repository + sheet dismissal.
struct NoteEditor: View {
    @Environment(\.superTheme) private var theme

    /// Whether the editor is composing a new note or revising an existing
    /// one. `edit` adds the Delete affordance; `create` shows the
    /// placeholder.
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

    // Text content scaled to Dynamic Type (the `BibleBookSheet` convention);
    // the toolbar's circular control glyphs stay fixed in their 34pt circles.
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
            grabber
            toolbar
            Rectangle()
                .fill(theme.borderFaint)
                .frame(height: 0.5)
            caption
            entry
            if mode == .edit {
                deleteSection
            }
        }
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

    private var grabber: some View {
        Capsule()
            .fill(theme.inkMute)
            .frame(width: 36, height: 4)
            .opacity(0.45)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .accessibilityHidden(true)
    }

    private var toolbar: some View {
        ZStack {
            Text(mode == .edit ? "Edit note" : "New note")
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(theme.ink)
            HStack {
                circleButton(symbol: "xmark", accent: false, enabled: true, action: onCancel)
                    .accessibilityLabel("Cancel")
                Spacer()
                circleButton(symbol: "checkmark", accent: true, enabled: canSave) {
                    // `canSave` gates on the trimmed value; forward the
                    // trimmed text too so a body of only whitespace can't be
                    // saved past the guard and leading/trailing space isn't
                    // persisted.
                    onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .accessibilityLabel("Save note")
                .disabled(!canSave)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func circleButton(
        symbol: String,
        accent: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(symbolColor(accent: accent, enabled: enabled))
                .frame(width: 34, height: 34)
                .background(Circle().fill(fillColor(accent: accent, enabled: enabled)))
                .contentShape(Circle())
                .opacity(enabled ? 1 : 0.6)
        }
        .buttonStyle(.plain)
    }

    private func fillColor(accent: Bool, enabled: Bool) -> Color {
        guard accent else { return theme.backgroundSunken }
        return enabled ? theme.accent : theme.backgroundSunken
    }

    private func symbolColor(accent: Bool, enabled: Bool) -> Color {
        guard accent else { return theme.inkSoft }
        return enabled ? theme.accentInk : theme.inkMute
    }

    private var caption: some View {
        Text("On \(citation)".uppercased())
            .font(.system(size: captionSize, weight: .medium, design: .monospaced))
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
                    .font(.system(size: entrySize))
                    .foregroundStyle(theme.inkFaint)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
                    // The TextEditor below owns the spoken label; hide the
                    // placeholder so VoiceOver doesn't announce both.
                    .accessibilityHidden(true)
            }
            TextEditor(text: $text)
                .font(.system(size: entrySize))
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
                        .font(.system(size: titleSize, weight: .medium))
                    Text("Delete note")
                        .font(.system(size: titleSize, weight: .semibold))
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
