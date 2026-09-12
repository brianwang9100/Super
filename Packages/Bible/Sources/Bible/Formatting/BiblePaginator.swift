import CoreText
import Foundation

enum BiblePaginationError: Error, Sendable, Equatable {
    case emptyChapter
    case viewportTooSmall
}

enum BiblePaginator {
    private struct MeasuredLine {
        let range: NSRange
        let indent: CGFloat
        let width: CGFloat
        let height: CGFloat
        let ascent: CGFloat
        let before: CGFloat
        let after: CGFloat
        let keepsNext: Bool
    }

    static func paginate(_ document: BiblePageDocument, size: CGSize) throws -> [BiblePage] {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw BiblePaginationError.viewportTooSmall
        }
        guard document.verseRanges.contains(where: { $0.range.length > 0 }) else { throw BiblePaginationError.emptyChapter }
        let typesetter = CTTypesetterCreateWithAttributedString(document.text)
        var measured: [MeasuredLine] = []
        for block in document.blocks {
            var cursor = block.range.location
            while cursor < NSMaxRange(block.range) {
                let width = size.width - block.indent
                guard width > 0 else { throw BiblePaginationError.viewportTooSmall }
                var length = min(CTTypesetterSuggestLineBreak(typesetter, cursor, width), NSMaxRange(block.range) - cursor)
                if length == 0 { length = min(CTTypesetterSuggestClusterBreak(typesetter, cursor, width), NSMaxRange(block.range) - cursor) }
                guard length > 0 else { throw BiblePaginationError.viewportTooSmall }
                let range = NSRange(location: cursor, length: length)
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: cursor, length: length))
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                let lineWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading) - CTLineGetTrailingWhitespaceWidth(line)
                let height = ceil(ascent + descent + leading)
                guard height <= size.height, lineWidth <= width + 0.01 else { throw BiblePaginationError.viewportTooSmall }
                measured.append(MeasuredLine(range: range, indent: block.indent, width: lineWidth,
                                             height: height, ascent: ascent,
                                             before: cursor == block.range.location ? block.spaceBefore : 0,
                                             after: NSMaxRange(range) == NSMaxRange(block.range) ? block.spaceAfter : document.lineSpacing,
                                             keepsNext: block.isHeading))
                cursor += length
            }
        }
        var pages: [BiblePage] = []
        var lines: [BiblePage.Line] = []
        var y: CGFloat = 0
        func finish() {
            guard let first = lines.first else { return }
            pages.append(BiblePage(position: document.position, translation: document.translation,
                                   lines: lines, locator: document.locator(at: first.range.location)))
            lines.removeAll(keepingCapacity: true)
            y = 0
        }
        for (index, item) in measured.enumerated() {
            let before = lines.isEmpty ? 0 : item.before
            var required = before + item.height
            if item.keepsNext, index + 1 < measured.count {
                let next = measured[index + 1]
                let together = required + item.after + next.before + next.height
                if together <= size.height { required = together }
            }
            if !lines.isEmpty && y + required > size.height { finish() }
            if !lines.isEmpty { y += item.before }
            lines.append(BiblePage.Line(range: item.range,
                                       frame: CGRect(x: item.indent, y: y, width: item.width, height: item.height),
                                       baseline: y + item.ascent))
            y += item.height + item.after
        }
        finish()
        return pages
    }
}
