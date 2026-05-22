import Foundation

/// Loads an applet-authored markdown prompt from its Swift Package Manager
/// (SPM) resource bundle.
///
/// Each `MiniApplet` returns its `systemPrompt` body by calling
/// `AppletSystemPrompt.load(from: .module)` from inside the applet's own
/// module — `.module` then resolves to that applet's bundle, so the same
/// one-liner works in every conformance without per-applet plumbing.
///
/// Missing or unreadable resources resolve to an empty string. The
/// downstream assembler treats empty bodies as "no block" and skips them,
/// so a placeholder applet that hasn't authored a prompt yet (or a
/// development checkout that omits the file) silently contributes
/// nothing rather than crashing.
public enum AppletSystemPrompt {
    /// Reads `<resource>.md` from `bundle`, trims surrounding whitespace,
    /// and returns the contents. Returns `""` when the resource is
    /// absent or unreadable.
    ///
    /// - Parameters:
    ///   - bundle: The applet's resource bundle. Conventionally `.module`
    ///     called from inside the applet's own source file.
    ///   - resource: Markdown filename without the `.md` extension.
    ///     Defaults to `"SystemPrompt"`.
    public static func load(from bundle: Bundle, resource: String = "SystemPrompt") -> String {
        guard let url = bundle.url(forResource: resource, withExtension: "md") else {
            return ""
        }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
