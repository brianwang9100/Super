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

    struct HeadingFragment: Identifiable {
        let text: String
        let sourceRange: NSRange
        let frame: CGRect
        var id: Int { sourceRange.location }
    }

    func headingFragments(in document: BiblePageDocument) -> [HeadingFragment] {
        document.blocks.filter(\.isHeading).compactMap { block in
            let range = NSIntersectionRange(block.range, sourceRange)
            guard range.length > 0 else { return nil }
            let text = (document.text.string as NSString).substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let frames = lines.compactMap { line -> CGRect? in
                let intersection = NSIntersectionRange(line.range, range)
                return intersection.length > 0 ? document.rect(for: intersection, on: line) : nil
            }
            return HeadingFragment(text: text, sourceRange: range, frame: frames.reduce(.null) { $0.union($1) })
        }
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
        for verse in order {
            guard let marker = document.verseMarkerRange(for: verse) else { continue }
            for line in lines {
                let intersection = NSIntersectionRange(line.range, marker)
                if intersection.length > 0 { frames[verse, default: []].append(document.rect(for: intersection, on: line)) }
            }
        }
        return order.map {
            Fragment(verseNumber: $0, text: texts[$0, default: ""],
                     sourceRange: ranges[$0]!, frames: frames[$0, default: []])
        }
    }
}
