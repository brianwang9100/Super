import Core
import Foundation

/// Loads Chat's default Large Language Model (LLM) system prompt from
/// the package's Swift Package Manager (SPM) resource bundle.
///
/// Lives in the Chat package (not in `App/`) so `Bundle.module` resolves
/// to Chat's bundle — `DefaultSystemPrompt.md` is bundled there, not in
/// the App target. The composition root reads this once at bootstrap
/// and hands the body to `ChatSessionStore` as the leading system
/// briefing for every conversation.
public enum ChatBriefing {
    /// Trimmed contents of `DefaultSystemPrompt.md`. Empty when the
    /// resource is absent — the session store's leading-system assembler
    /// drops empty bodies, so a missing file degrades gracefully.
    public static func load() -> String {
        AppletSystemPrompt.load(from: .module, resource: "DefaultSystemPrompt")
    }

    /// Trimmed contents of `DefaultSystemPrompt.compact.md` — the lean
    /// persona variant `ChatSession` sends to small-context-window models
    /// (`ModelContextTier.compact`). Empty when absent; the session falls
    /// back to the full briefing in that case.
    public static func loadCompact() -> String {
        AppletSystemPrompt.load(from: .module, resource: "DefaultSystemPrompt.compact")
    }
}
