import CoreText
import Foundation

struct BiblePageDocument {
    struct Decorations: Equatable {
        var annotations: [Int: [BibleAnnotationTargetSpec]] = [:]
        var notes: [Int: [BibleNoteTargetSpec]] = [:]
    }

    struct Trailer {
        enum Kind { case annotation(BibleAnnotationTargetSpec), note(BibleNoteTargetSpec) }
        let range: NSRange
        let kind: Kind
    }

    private struct SupplementRange {
        let id: String
        let range: NSRange
        let verseNumber: Int?
    }

    struct VerseRange {
        let verseNumber: Int
        let range: NSRange
        let verseOffset: Int
    }

    struct Block {
        let range: NSRange
        let isHeading: Bool
        let indent: CGFloat
        let spaceBefore: CGFloat
        let spaceAfter: CGFloat
    }

    let text: NSAttributedString
    let position: BiblePosition
    let translation: BibleTranslation
    let verseRanges: [VerseRange]
    let blocks: [Block]
    let trailers: [Trailer]
    let lineSpacing: CGFloat
    private let supplementRanges: [SupplementRange]

    init(chapter: BibleChapter, position: BiblePosition, translation: BibleTranslation,
         bodyFont: CTFont, headingFont: CTFont, numberFont: CTFont, decorations: Decorations = .init()) {
        self.position = position
        self.translation = translation
        lineSpacing = CTFontGetSize(bodyFont) * 4 / 17
        let result = NSMutableAttributedString(string: "")
        var ranges: [VerseRange] = []
        var blocks: [Block] = []
        var trailers: [Trailer] = []
        var supplements: [SupplementRange] = []
        var verseOffsets: [Int: Int] = [:]
        var remaining: [Int: Int] = [:]
        for paragraph in chapter.paragraphs {
            switch paragraph {
            case .heading: break
            case .prose(let verses), .poetry(let verses):
                for verse in verses { remaining[verse.number, default: 0] += 1 }
            }
        }
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let contextColor = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
        func append(_ string: String, font: CTFont) {
            result.append(NSAttributedString(string: string, attributes: [fontKey: font, contextColor: true]))
        }
        for (paragraphIndex, paragraph) in chapter.paragraphs.enumerated() {
            let start = result.length
            let heading: Bool
            let indent: CGFloat
            switch paragraph {
            case .heading(let title):
                heading = true
                indent = 0
                append(title + "\n", font: headingFont)
                supplements.append(SupplementRange(id: "heading:\(paragraphIndex)",
                    range: NSRange(location: start, length: result.length - start), verseNumber: nil))
            case .prose(let verses), .poetry(let verses):
                heading = false
                if case .poetry = paragraph { indent = 20 } else { indent = 0 }
                for (index, verse) in verses.enumerated() {
                    if index > 0 {
                        supplements.append(SupplementRange(id: "separator:\(paragraphIndex):\(index)",
                            range: NSRange(location: result.length, length: 1), verseNumber: verse.number))
                        append(" ", font: bodyFont)
                    }
                    let offset = verseOffsets[verse.number, default: 0]
                    if verseOffsets[verse.number] == nil {
                        let markerStart = result.length
                        result.append(NSAttributedString(string: "\(verse.number)\u{202F}\u{2060}", attributes: [
                            fontKey: numberFont, contextColor: true,
                            NSAttributedString.Key(kCTBaselineOffsetAttributeName as String): CTFontGetSize(bodyFont) * 0.25,
                        ]))
                        supplements.append(SupplementRange(id: "marker:\(verse.number)",
                            range: NSRange(location: markerStart, length: result.length - markerStart),
                            verseNumber: verse.number))
                    }
                    let range = NSRange(location: result.length, length: verse.text.utf16.count)
                    append(verse.text, font: bodyFont)
                    ranges.append(VerseRange(verseNumber: verse.number, range: range, verseOffset: offset))
                    verseOffsets[verse.number] = offset + range.length
                    remaining[verse.number, default: 0] -= 1
                    if remaining[verse.number] == 0 {
                        let kinds = decorations.annotations[verse.number, default: []].map(Trailer.Kind.annotation)
                            + decorations.notes[verse.number, default: []].map(Trailer.Kind.note)
                        for kind in kinds {
                            let range = NSRange(location: result.length, length: 1)
                            result.append(Self.trailerPlaceholder(size: CTFontGetSize(bodyFont)))
                            trailers.append(Trailer(range: range, kind: kind))
                            let id: String
                            switch kind {
                            case .annotation(let spec): id = "annotation:\(verse.number):\(spec.id)"
                            case .note(let spec): id = "note:\(verse.number):\(spec.id)"
                            }
                            supplements.append(SupplementRange(id: id, range: range, verseNumber: verse.number))
                        }
                    }
                }
                supplements.append(SupplementRange(id: "paragraph-end:\(paragraphIndex)",
                    range: NSRange(location: result.length, length: 1), verseNumber: nil))
                append("\n", font: bodyFont)
            }
            blocks.append(Block(range: NSRange(location: start, length: result.length - start),
                                isHeading: heading, indent: indent,
                                spaceBefore: heading ? CTFontGetSize(bodyFont) * 0.6 : 0,
                                spaceAfter: heading ? 4 : CTFontGetSize(bodyFont) * 0.45))
        }
        text = NSAttributedString(attributedString: result)
        verseRanges = ranges
        self.blocks = blocks
        self.trailers = trailers
        supplementRanges = supplements
    }

    private static func trailerPlaceholder(size: CGFloat) -> NSAttributedString {
        let metrics = UnsafeMutablePointer<CGFloat>.allocate(capacity: 1)
        metrics.initialize(to: size)
        var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateCurrentVersion,
            dealloc: { pointer in
                let metrics = pointer.assumingMemoryBound(to: CGFloat.self)
                metrics.deinitialize(count: 1)
                metrics.deallocate()
            },
            getAscent: { $0.assumingMemoryBound(to: CGFloat.self).pointee * 0.8 },
            getDescent: { $0.assumingMemoryBound(to: CGFloat.self).pointee * 0.2 },
            getWidth: { $0.assumingMemoryBound(to: CGFloat.self).pointee + 8 })
        guard let delegate = CTRunDelegateCreate(&callbacks, metrics) else {
            metrics.deinitialize(count: 1); metrics.deallocate()
            return NSAttributedString(string: " ")
        }
        return NSAttributedString(string: "\u{FFFC}", attributes: [
            NSAttributedString.Key(kCTRunDelegateAttributeName as String): delegate,
        ])
    }

    func locator(at characterIndex: Int) -> BibleTextLocator {
        let supplement = supplementRanges.first { $0.range.contains(characterIndex) }
        let source = supplement?.verseNumber.flatMap { verse in
            verseRanges.last { $0.verseNumber == verse && $0.range.location <= characterIndex }
                ?? verseRanges.first { $0.verseNumber == verse }
        }
            ?? verseRanges.first { NSMaxRange($0.range) > characterIndex } ?? verseRanges.last
        var locator = BibleTextLocator(position: position, translation: translation,
                                       verseNumber: source?.verseNumber ?? 1,
                                       utf16Offset: source.map {
                                           $0.verseOffset + max(0, min($0.range.length - 1, characterIndex - $0.range.location))
                                       } ?? 0)
        if let supplement {
            locator.supplement = .init(id: supplement.id, utf16Offset: characterIndex - supplement.range.location)
        }
        return locator
    }

    func characterIndex(for locator: BibleTextLocator) -> Int {
        if let supplement = locator.supplement, supplement.utf16Offset >= 0,
           let range = supplementRanges.first(where: { $0.id == supplement.id })?.range {
            return range.location + min(supplement.utf16Offset, max(0, range.length - 1))
        }
        let ranges = verseRanges.filter { $0.verseNumber == locator.verseNumber }
        guard let first = ranges.first else { return verseRanges.first?.range.location ?? 0 }
        guard locator.utf16Offset >= 0,
              let range = ranges.first(where: { $0.verseOffset + $0.range.length > locator.utf16Offset }) else {
            return first.range.location
        }
        return range.range.location + max(0, locator.utf16Offset - range.verseOffset)
    }

    func rect(for range: NSRange, on line: BiblePage.Line) -> CGRect {
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: line.range.location, length: line.range.length))
        let start = CTLineGetOffsetForStringIndex(ctLine, range.location, nil)
        let end = CTLineGetOffsetForStringIndex(ctLine, NSMaxRange(range), nil)
        return CGRect(x: line.frame.minX + min(start, end), y: line.frame.minY,
                      width: max(1, abs(end - start)), height: line.frame.height)
    }
}
