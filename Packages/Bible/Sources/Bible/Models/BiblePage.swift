import Foundation
import CoreGraphics

struct BiblePage: Equatable, Identifiable {
    let position: BiblePosition
    let translation: BibleTranslation
    let lines: [Line]
    let locator: BibleTextLocator
    var id: String { "\(position.bookId)/\(position.chapterNumber)/\(translation.rawValue)/\(sourceRange.location)" }

    struct Line: Equatable {
        let range: NSRange
        let frame: CGRect
        let baseline: CGFloat
    }

    struct Fragment: Identifiable {
        let verseNumber: Int
        let text: String
        let sourceRange: NSRange
        let frames: [CGRect]
        var id: Int { verseNumber }
    }

    var sourceRange: NSRange {
        guard let first = lines.first, let last = lines.last else { return NSRange(location: 0, length: 0) }
        return NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
    }

    func contains(_ locator: BibleTextLocator, in document: BiblePageDocument) -> Bool {
        locator.position == position && locator.translationId == translation.rawValue
            && sourceRange.contains(document.characterIndex(for: locator))
    }

    func fragments(in document: BiblePageDocument) -> [Fragment] {
        var order: [Int] = []
        var texts: [Int: String] = [:]
        var ranges: [Int: NSRange] = [:]
        var frames: [Int: [CGRect]] = [:]
        for verse in document.verseRanges {
            let intersection = NSIntersectionRange(verse.range, sourceRange)
            guard intersection.length > 0 else { continue }
            if texts[verse.verseNumber] == nil { order.append(verse.verseNumber) }
            texts[verse.verseNumber, default: ""] += (document.text.string as NSString).substring(with: intersection)
            ranges[verse.verseNumber] = ranges[verse.verseNumber].map { NSUnionRange($0, intersection) } ?? intersection
            for line in lines {
                let part = NSIntersectionRange(line.range, intersection)
                guard part.length > 0 else { continue }
                frames[verse.verseNumber, default: []].append(document.rect(for: part, on: line))
            }
        }
        return order.map {
            Fragment(verseNumber: $0, text: texts[$0, default: ""],
                     sourceRange: ranges[$0]!, frames: frames[$0, default: []])
        }
    }
}
