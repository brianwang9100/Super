import Chat
import Core
import Foundation

/// Target-neutral shell dependencies; applet-specific dependencies stay in each bootstrap.
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
    /// Share one engine with every applet so the Settings toggle mutes all surfaces.
    let hapticsEngine: any HapticsEngine
    let launchBehavior: AppShellLaunchBehavior
    /// Shared between the backdrop writer and accessory renderer; nil disables the accessory row.
    let composerAccessoryStore: ComposerAccessoryStore?
    var providerAudioSetup: ProviderAudioSetup?
    var audioActivity: AudioActivity?
}
