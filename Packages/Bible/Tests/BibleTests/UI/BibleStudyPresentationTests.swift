import Core
import Testing
@testable import Bible

/// Native sheet handoffs capture targets, preserve glyph selection, and finish only after dismissal.
@Suite("Bible study presentation")
@MainActor
struct BibleStudyPresentationTests {
    private struct UnacknowledgedDisclaimerStore: AnnotationDisclaimerStore {
        var isAcknowledged: Bool { false }
        func setAcknowledged(_ value: Bool) {}
    }

    private func makeModel() async -> BibleScreenViewModel {
        let model = BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            disclaimerStore: UnacknowledgedDisclaimerStore(),
            initialPosition: BiblePosition(bookId: "ROM", chapterNumber: 8),
            narration: NarrationController(service: FakeNarrationService())
        )
        await model.load()
        return model
    }

    @Test("closing actions preserves selection and deselecting the final verse closes actions")
    func selectionClose() async {
        let model = await makeModel()
        model.toggleVerse(28)
        model.dismissActionSheet()
        #expect(model.selectedVerses == [28])
        model.presentActionSheet()
        model.toggleVerse(28)
        #expect(!model.isActionSheetPresented)
    }

    @Test("note action captures its target and waits for action dismissal")
    func noteHandoff() async {
        let model = await makeModel()
        let presentation = BibleStudyPresentationViewModel(viewModel: model)
        model.toggleVerse(28)
        presentation.addNoteForSelection()
        #expect(model.selectedVerses.isEmpty)
        #expect(model.presentedNoteList == nil)
        presentation.didDismiss(.bottom, identity: presentation.identity)
        #expect(model.presentedNoteList?.spec == .verseRange(bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 28))
        #expect(model.presentedNoteList?.autoCompose == true)
    }

    @Test("annotation action waits for action dismissal before showing disclaimer")
    func annotationHandoff() async {
        let model = await makeModel()
        let presentation = BibleStudyPresentationViewModel(viewModel: model)
        model.toggleVerse(28)
        presentation.annotateSelection()
        #expect(!model.isAnnotationDisclaimerPresented)
        presentation.didDismiss(.bottom, identity: presentation.identity)
        #expect(model.isAnnotationDisclaimerPresented)
        #expect(model.pendingAnnotationIntents.count == 1)
    }

    @Test("chapter navigation invalidates deferred work before native dismissal", arguments: [false, true])
    func changedChapterRejectsHandoff(fromBook: Bool) async {
        let model = await makeModel()
        let presentation = BibleStudyPresentationViewModel(viewModel: model)
        let sheet: BibleStudyPresentationViewModel.Sheet
        if fromBook {
            sheet = .book
            model.presentBookSheet()
            presentation.handOffAfterBookDismiss { model.presentNoteList(for: .book(bookId: "ROM")) }
        } else {
            sheet = .bottom
            model.toggleVerse(28)
            presentation.addNoteForSelection()
        }
        model.selectChapter(bookId: "JHN", chapterNumber: 3)
        // Native dismissal may run before BibleScreen observes the position change.
        presentation.didDismiss(sheet, identity: presentation.identity)
        #expect(model.presentedNoteList == nil)
        #expect(model.position == BiblePosition(bookId: "JHN", chapterNumber: 3))
    }

    @Test("invalidating a host prevents a dismissed action from resurrecting a note")
    func invalidatedHandoff() async {
        let model = await makeModel()
        let presentation = BibleStudyPresentationViewModel(viewModel: model)
        model.toggleVerse(28)
        presentation.addNoteForSelection()
        presentation.invalidate()
        presentation.didDismiss(.bottom, identity: presentation.identity)
        #expect(model.presentedNoteList == nil)
    }

    @Test("finish supersedes queued work and waits for native dismissal exactly once")
    func finishWaitsForDismissal() async {
        let model = await makeModel()
        let presentation = BibleStudyPresentationViewModel(viewModel: model)
        model.toggleVerse(28)
        presentation.addNoteForSelection()
        var completed = 0
        presentation.finish { completed += 1 }
        #expect(completed == 0)
        presentation.didDismiss(.bottom, identity: presentation.identity)
        #expect(completed == 1)
        #expect(model.presentedNoteList == nil)
        presentation.didDismiss(.bottom, identity: presentation.identity)
        #expect(completed == 1)
    }

    @Test("finish waits for both nested study and underlying actions")
    func finishNestedSheets() async {
        let model = await makeModel()
        let presentation = BibleStudyPresentationViewModel(viewModel: model)
        model.toggleVerse(28)
        model.presentNoteList(for: .chapter(bookId: "ROM", chapterNumber: 8))
        var completed = false
        presentation.finish { completed = true }
        #expect(model.presentedNoteList == nil)
        #expect(!model.isActionSheetPresented)
        presentation.didDismiss(.note, identity: presentation.identity)
        #expect(!completed)
        presentation.didDismiss(.bottom, identity: presentation.identity)
        #expect(completed)
    }

    @Test("glyph notes retain selection and narration transport returns on close", arguments: [false, true])
    func narrationNote(selected: Bool) async {
        let model = await makeModel()
        if selected { model.toggleVerse(28) }
        model.startNarration()
        model.narration._simulateEvent(.started(verseNumber: 28))
        model.presentNoteList(for: .chapter(bookId: "ROM", chapterNumber: 8))
        model.dismissNoteList()
        #expect(model.selectedVerses == (selected ? [28] : []))
        #expect(model.isNarrationSheetPresented)
        #expect(model.narration.state == .speaking)
    }

    @Test("bookmark clears selection without dismissing narration", arguments: [false, true])
    func narrationBookmark(selected: Bool) async {
        let model = await makeModel()
        let presentation = BibleStudyPresentationViewModel(viewModel: model)
        if selected { model.toggleVerse(28) }
        model.startNarration()
        model.narration._simulateEvent(.started(verseNumber: 28))
        presentation.presentBookmark()
        #expect(model.presentedBookmarkSheet != nil)
        #expect(model.selectedVerses.isEmpty)
        model.dismissBookmarkSheet()
        #expect(model.isNarrationSheetPresented)
        #expect(model.narration.state == .speaking)
    }

    @Test("bookmark waits for visible actions before presenting")
    func bookmarkHandoff() async {
        let model = await makeModel()
        let presentation = BibleStudyPresentationViewModel(viewModel: model)
        model.toggleVerse(28)
        presentation.presentBookmark()
        #expect(model.presentedBookmarkSheet == nil)
        #expect(model.selectedVerses.isEmpty)
        presentation.didDismiss(.bottom, identity: presentation.identity)
        #expect(model.presentedBookmarkSheet != nil)
    }
    @Test("dismissal from an invalidated lifetime cannot run the new host's handoff")
    func staleDismissal() async {
        let model = await makeModel()
        let presentation = BibleStudyPresentationViewModel(viewModel: model)
        let oldIdentity = presentation.identity
        presentation.invalidate()
        presentation.activate()
        model.toggleVerse(28)
        presentation.addNoteForSelection()
        presentation.didDismiss(.bottom, identity: oldIdentity)
        #expect(model.presentedNoteList == nil)
        presentation.didDismiss(.bottom, identity: presentation.identity)
        #expect(model.presentedNoteList != nil)
    }

    @Test("finish still waits after interactive dismissal clears the model binding")
    func finishDuringInteractiveDismissal() async {
        let model = await makeModel()
        let presentation = BibleStudyPresentationViewModel(viewModel: model)
        model.toggleVerse(28)
        presentation.didPresent(.bottom, identity: presentation.identity)
        model.dismissActionSheet()
        var completed = false
        presentation.finish { completed = true }
        #expect(!completed)
        presentation.didDismiss(.bottom, identity: presentation.identity)
        #expect(completed)
    }

    @Test("glyph annotation preserves selected verses")
    func annotationGlyphSelection() async {
        let model = await makeModel()
        model.toggleVerse(28)
        model.presentAnnotationSheet(for: .chapter(bookId: "ROM", chapterNumber: 8))
        model.dismissAnnotationSheet()
        #expect(model.selectedVerses == [28])
    }

    @Test("book picker hands off only after its own native dismissal")
    func bookHandoff() async {
        let model = await makeModel()
        let presentation = BibleStudyPresentationViewModel(viewModel: model)
        model.presentBookSheet()
        presentation.handOffAfterBookDismiss { model.presentNoteList(for: .book(bookId: "ROM")) }
        #expect(model.presentedNoteList == nil)
        presentation.didDismiss(.bottom, identity: presentation.identity)
        #expect(model.presentedNoteList == nil)
        presentation.didDismiss(.book, identity: presentation.identity)
        #expect(model.presentedNoteList?.spec == .book(bookId: "ROM"))
    }

    @Test("bookmark tapped during action dismissal waits for that dismissal")
    func bookmarkDuringDismissal() async {
        let model = await makeModel()
        let presentation = BibleStudyPresentationViewModel(viewModel: model)
        model.toggleVerse(28)
        presentation.didPresent(.bottom, identity: presentation.identity)
        model.dismissActionSheet()
        presentation.presentBookmark()
        #expect(model.presentedBookmarkSheet == nil)
        presentation.didDismiss(.bottom, identity: presentation.identity)
        #expect(model.presentedBookmarkSheet != nil)
    }
}
