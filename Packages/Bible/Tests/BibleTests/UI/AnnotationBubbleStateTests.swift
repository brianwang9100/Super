import Testing
@testable import Bible

@Suite("AnnotationBubble.state")
@MainActor
struct AnnotationBubbleStateTests {
    @Test("rows present render filled")
    func filledWhenAnnotated() {
        #expect(AnnotationBubble.state(hasAnnotation: true, isGenerating: false) == .filled)
    }

    @Test("filled wins over generating so existing rows stay viewable mid-regenerate")
    func filledWinsOverGenerating() {
        #expect(AnnotationBubble.state(hasAnnotation: true, isGenerating: true) == .filled)
    }

    @Test("no rows with a dispatch in flight render generating")
    func generatingWhenNoRows() {
        #expect(AnnotationBubble.state(hasAnnotation: false, isGenerating: true) == .generating)
    }

    @Test("no rows and no dispatch render empty")
    func emptyByDefault() {
        #expect(AnnotationBubble.state(hasAnnotation: false, isGenerating: false) == .empty)
    }
}
