import Chat
import Core
import Foundation

/// Slice of the bootstrap dependency graph that `AppShell` actually
/// consumes. Both `SuperOSAppBootstrap` and `SuperBibleAppBootstrap`
/// produce one of these — the former via a computed `shellDependencies`
/// property on `AppDependencies`, the latter the same on
/// `SuperBibleAppDependencies`. Sharing the type keeps the shell
/// genuinely target-neutral instead of being templated over a protocol.
///
/// Deliberately omits applet-set-specific fields (Todo's
/// `TodoDependencies`, SuperOS-only `registeredToolIDs`) — those stay on
/// the target-specific dependency types and never reach this layer.
/// `AppletRegistry` is included because the shell uses it to drive the
/// sidebar rail and the backdrop swap; each target's bootstrap pre-fills
/// the registry with its own applet set.
@MainActor
struct AppShellDependencies {
    let chatDatabase: ChatDatabase
    let chatSessionStore: ChatSessionStore
    let toolRegistry: ToolRegistry
    let llmProviderRegistry: LLMProviderRegistry
    let conversationRepository: any ConversationRepository
    let messageRepository: any MessageRepository
    let toolCallRepository: any ToolCallRepository
    let checkpointRepository: any CompactionCheckpointRepository
    let modelConfigurationRepository: any ModelConfigurationRepository
    let settingRepository: any SettingRepository
    let memoryRepository: any MemoryRepository
    let eventBus: SuperEventBus
    let appletRegistry: AppletRegistry
    let appleFoundationAvailability: AppleFoundationAvailability
    /// User identity rendered in the sidebar drawer header and the
    /// Settings → account row. Each target supplies its own value —
    /// SuperOS hard-codes the founder's identity (single-user MVP);
    /// SuperBible passes empty strings until real user identity lands
    /// at SB-M3+ (the drawer header and settings row degrade gracefully
    /// to empty / placeholder display rather than mis-attributing the
    /// app to a stranger). Real account auth is tracked in the
    /// SuperBible fork spec §7 (CloudKit + Sign in with Apple).
    let userInitials: String
    let userName: String
    let accountEmail: String
}
