import Core
import SwiftUI

/// A fixed chapter with local selection and study sheets above its native presentation.
struct BibleChapterPreviewSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @State var viewModel: BibleChapterPreviewViewModel
    var annotationRepository: (any BibleAnnotationRepository)?

    var body: some View {
        VStack(spacing: 0) {
            SheetNavBar(
                title: viewModel.reader.selectionCitation
                    ?? "\(viewModel.reader.bookName) \(viewModel.reader.position.chapterNumber)",
                subtitle: viewModel.reader.translation.rawValue,
                onClose: { viewModel.cancel() }
            ) {
                Button { viewModel.openInBible() } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(typography.font(size: 18, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .frame(width: 44, height: 44)
                        .superGlassButton(in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open in Bible")
                .accessibilityHint("Open this chapter and selection in Bible")
            }

            BibleChapterContent(
                viewModel: viewModel.reader,
                layout: viewModel.reader.selectedVerses.isEmpty ? .preview : .previewWithSelection,
                overlayKind: viewModel.reader.isActionSheetPresented ? .selection : nil,
                onAnnotationBubbleTap: { viewModel.reader.presentAnnotationSheet(for: $0) },
                onRequestChapterAnnotation: { viewModel.reader.triggerAnnotationGeneration(for: $0) },
                onNoteGlyphTap: { viewModel.reader.presentNoteList(for: $0) },
                onBookmarkTap: { viewModel.study.presentBookmark() }
            )
            .allowsHitTesting(viewModel.isReady)

            .overlay(alignment: .bottom) {
                if let citation = viewModel.reader.selectionCitation {
                    SelectionPill(title: citation, accessibilityLabel: "Actions for \(citation)",
                                  onAction: { viewModel.reopenActions() },
                                  onClear: { viewModel.reader.clearSelection() },
                                  disclosureSystemImage: "chevron.up")
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                }
            }
        }
        .background(theme.background)
        .overlay(alignment: .bottom) {
            if let toast = viewModel.reader.toast {
                BibleAttachToast(message: toast, onDismiss: { viewModel.reader.dismissToast() })
            }
        }
        .background {
            BiblePreviewPresentationObserver(identity: viewModel.identity,
                                             onReady: { viewModel.presentationDidComplete(identity: $0) },
                                             onUnmount: { viewModel.invalidate() })
                .frame(width: 0, height: 0)
        }
        .modifier(BibleStudySheetsModifier(
            viewModel: viewModel.reader,
            presentation: viewModel.study,
            annotationRepository: annotationRepository,
            bibleLinkPolicy: .plainText,
            onOpenLink: { _ in },
            onAddToChat: { viewModel.addToChat(reference: $0, startNewConversation: $1) }
        ))
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(theme.background)
    }
}
