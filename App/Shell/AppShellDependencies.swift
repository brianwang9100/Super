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
    /// Shared app-wide haptics engine. One instance per app: injected into the
    /// SwiftUI environment (sidebar/hamburger taps), the chat + Settings view
    /// models, and each applet's view models, so the Settings toggle mutes
    /// every surface at once. Each target's bootstrap also threads the same
    /// instance into the applets it registers (e.g. `BibleApplet`).
    let hapticsEngine: any HapticsEngine
    /// Per-target cold-launch defaults. SuperOS passes `.standard`
    /// (chat opens expanded over last-used applet). SuperBible passes
    /// `AppShellLaunchBehavior(initialChatState: .minimized)` so Bible
    /// is visible and the chat sits as a pill on every cold launch.
    let launchBehavior: AppShellLaunchBehavior
    /// Shared holder for the chat composer's hovering flank buttons (e.g. the
    /// Bible reader's previous / next chapter chevrons). Non-`nil` only on
    /// targets that opt into the behavior (SuperBible); SuperOS passes `nil`,
    /// so the shell renders no accessory row and injects nothing into the
    /// backdrop. The shell injects this into the backdrop subtree (so the
    /// active applet can publish controls) and reads it for the composer
    /// accessory layer.
    let composerAccessoryStore: ComposerAccessoryStore?
    var providerAudioSetup: ProviderAudioSetup? = nil
    var audioActivity: AudioActivity? = nil
}
