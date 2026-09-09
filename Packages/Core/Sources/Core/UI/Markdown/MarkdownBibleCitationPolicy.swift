import Foundation
import SwiftUI
internal import cmark_gfm
internal import cmark_gfm_extensions

/// Controls whether shared Markdown prose can navigate through Bible citations.
public enum MarkdownBibleCitationPolicy: Sendable, Equatable {
    /// Automatically link citations and retain explicit internal links.
    case enabled
    /// Retain citation labels and formatting without internal-link navigation or accessibility traits.
    case plainText

    func resolve(_ markdown: String) -> String {
        switch self {
        case .enabled:
            BibleReferenceLinkifier.linkify(markdown)
        case .plainText:
            InternalMarkdownLinks.removingLinks(from: markdown)
        }
    }
}

private struct MarkdownBibleCitationPolicyKey: EnvironmentKey {
    static let defaultValue = MarkdownBibleCitationPolicy.enabled
}

extension EnvironmentValues {
    /// Citation behavior inherited by every `MarkdownText` in a presentation.
    public var markdownBibleCitationPolicy: MarkdownBibleCitationPolicy {
        get { self[MarkdownBibleCitationPolicyKey.self] }
        set { self[MarkdownBibleCitationPolicyKey.self] = newValue }
    }
}

/// Reuses MarkdownUI's parser and extensions so code and reference-link syntax stay intact.
private enum InternalMarkdownLinks {
    static func removingLinks(from markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return "" }
        defer { cmark_parser_free(parser) }

        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            if let syntax = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, syntax)
            }
        }
        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }

        guard unwrapLinks(in: document) else { return markdown }
        guard let output = cmark_render_commonmark(document, CMARK_OPT_DEFAULT, 0) else { return "" }
        defer { free(output) }
        return String(cString: output)
    }

    private static func unwrapLinks(in parent: UnsafeMutablePointer<cmark_node>) -> Bool {
        var changed = false
        var current = cmark_node_first_child(parent)
        while let node = current {
            // Save the sibling before the current node is unlinked and freed.
            current = cmark_node_next(node)
            if unwrapLinks(in: node) { changed = true }
            guard cmark_node_get_type(node) == CMARK_NODE_LINK,
                  let destination = cmark_node_get_url(node),
                  String(cString: destination).prefix(6).lowercased() == "super:" else { continue }

            while let child = cmark_node_first_child(node) {
                cmark_node_insert_before(node, child)
            }
            cmark_node_unlink(node)
            cmark_node_free(node)
            changed = true
        }
        return changed
    }
}
