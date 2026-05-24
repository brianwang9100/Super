import Core
import Foundation
import Testing
@testable import Chat

/// Tests for `LLMProviderCatalog` and the create-flow seed helper that
/// the Add-Model two-dropdown picker relies on. Snapshot tests anchor
/// the rendered result; these tests pin the catalog shape + the exact
/// field values a provider selection seeds so a refactor of the picker
/// UI can't silently change what gets persisted on Save without also
/// breaking these.
@Suite("LLMProviderCatalog + Add-Model create seeds")
struct SettingsModelDetailPaneCatalogTests {
    // MARK: - Catalog invariants

    @Test("Every provider has a non-empty id and display name")
    func providersHaveIdentity() {
        for entry in LLMProviderCatalog.all {
            #expect(!entry.id.isEmpty, "provider id must not be empty")
            #expect(!entry.displayName.isEmpty, "provider \(entry.id) needs a display name")
        }
    }

    @Test("Provider ids are unique")
    func providerIdsAreUnique() {
        let ids = LLMProviderCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate provider ids: \(ids)")
    }

    @Test("Every non-Custom provider has at least one model")
    func nonCustomProvidersHaveModels() {
        for entry in LLMProviderCatalog.all where entry.id != LLMProviderCatalog.customProviderID {
            #expect(!entry.models.isEmpty, "provider \(entry.id) must have ≥1 model")
        }
    }

    @Test("Custom provider has no catalog models")
    func customHasNoModels() {
        let custom = LLMProviderCatalog.entry(forID: LLMProviderCatalog.customProviderID)
        #expect(custom != nil)
        #expect(custom?.models.isEmpty == true)
    }

    @Test("Every non-Apple, non-Custom provider has a non-nil defaultBaseURL")
    func openAICompatProvidersHaveURL() {
        for entry in LLMProviderCatalog.all {
            if entry.id == LLMProviderCatalog.appleProviderID { continue }
            if entry.id == LLMProviderCatalog.customProviderID { continue }
            #expect(entry.defaultBaseURL != nil, "provider \(entry.id) needs a defaultBaseURL")
        }
    }

    @Test("Apple provider uses .appleFoundation kind; everyone else .openAICompatible")
    func providerKindsMatchExpectations() {
        for entry in LLMProviderCatalog.all {
            if entry.id == LLMProviderCatalog.appleProviderID {
                #expect(entry.kind == .appleFoundation)
            } else {
                #expect(entry.kind == .openAICompatible, "provider \(entry.id) should route through openAI-compat")
            }
        }
    }

    @Test("Every catalog model has a positive maxContextTokens")
    func modelMaxContextIsPositive() {
        for entry in LLMProviderCatalog.all {
            for model in entry.models {
                #expect(model.maxContextTokens > 0, "\(entry.id)/\(model.id) needs a positive maxContextTokens")
            }
        }
    }

    @Test("Every catalog model has a non-empty id and display name")
    func modelsHaveIdentity() {
        for entry in LLMProviderCatalog.all {
            for model in entry.models {
                #expect(!model.id.isEmpty)
                #expect(!model.displayName.isEmpty)
            }
        }
    }

    // MARK: - Lookup helpers

    @Test("entry(forID:) returns the matching provider")
    func entryLookupHit() {
        #expect(LLMProviderCatalog.entry(forID: "google")?.displayName == "Google")
        #expect(LLMProviderCatalog.entry(forID: "openai")?.kind == .openAICompatible)
    }

    @Test("entry(forID:) returns nil for unknown id")
    func entryLookupMiss() {
        #expect(LLMProviderCatalog.entry(forID: "made-up") == nil)
    }

    @Test("model(forModelId:) resolves a known id to (provider, model)")
    func modelLookupHit() {
        let result = LLMProviderCatalog.model(forModelId: "gemini-3-pro")
        #expect(result?.provider.id == "google")
        #expect(result?.model.displayName == "Gemini 3 Pro")
        #expect(result?.model.maxContextTokens == 1_000_000)
    }

    @Test("model(forModelId:) returns nil for an unknown wire id")
    func modelLookupMiss() {
        #expect(LLMProviderCatalog.model(forModelId: "totally-made-up-2027") == nil)
    }

    // MARK: - Create-flow seeds

    @Test("Apple seeds the on-device AFM shape (no URL, system-default model)")
    func appleSeeds() {
        let seeds = SettingsModelDetailPane.makeCreateSeeds(providerID: LLMProviderCatalog.appleProviderID)
        #expect(seeds.providerID == LLMProviderCatalog.appleProviderID)
        #expect(seeds.name == "Apple Intelligence")
        #expect(seeds.modelId == "system-default")
        #expect(seeds.modelCatalogID == "system-default")
        #expect(seeds.maxContextText == "4096")
        #expect(seeds.supportsThinking == false)
        // AFM has no URL — the field isn't rendered for this provider.
        #expect(seeds.baseURLText == "")
    }

    @Test("Google seeds Gemini 3 Pro with the OpenAI-compat shim URL")
    func googleSeeds() {
        let seeds = SettingsModelDetailPane.makeCreateSeeds(providerID: "google")
        #expect(seeds.name == "Gemini 3 Pro")
        #expect(seeds.modelId == "gemini-3-pro")
        #expect(seeds.baseURLText == "https://generativelanguage.googleapis.com/v1beta/openai/")
        #expect(seeds.maxContextText == "1000000")
        #expect(seeds.supportsThinking == true)
    }

    @Test("OpenAI seeds GPT-5.5 by default")
    func openAISeeds() {
        let seeds = SettingsModelDetailPane.makeCreateSeeds(providerID: "openai")
        #expect(seeds.name == "GPT-5.5")
        #expect(seeds.modelId == "gpt-5.5")
        #expect(seeds.baseURLText == "https://api.openai.com/v1")
        #expect(seeds.maxContextText == "1000000")
        #expect(seeds.supportsThinking == true)
    }

    @Test("Anthropic seeds Opus 4.7 with the OpenAI-compat shim URL and thinking ON")
    func anthropicSeeds() {
        let seeds = SettingsModelDetailPane.makeCreateSeeds(providerID: "anthropic")
        #expect(seeds.name == "Opus 4.7")
        #expect(seeds.modelId == "claude-opus-4-7")
        #expect(seeds.baseURLText == "https://api.anthropic.com/v1/openai/")
        #expect(seeds.maxContextText == "1000000")
        #expect(seeds.supportsThinking == true)
    }

    @Test("xAI seeds Grok 4.3 with thinking ON by default")
    func xaiSeeds() {
        let seeds = SettingsModelDetailPane.makeCreateSeeds(providerID: "xai")
        #expect(seeds.name == "Grok 4.3")
        #expect(seeds.modelId == "grok-4.3")
        #expect(seeds.baseURLText == "https://api.x.ai/v1")
        #expect(seeds.maxContextText == "1000000")
        #expect(seeds.supportsThinking == true)
    }

    @Test("Custom seeds empty name + empty model id + OpenAI placeholder URL")
    func customSeeds() {
        let seeds = SettingsModelDetailPane.makeCreateSeeds(providerID: LLMProviderCatalog.customProviderID)
        #expect(seeds.name == "")
        #expect(seeds.modelId == "")
        #expect(seeds.modelCatalogID == "")
        #expect(seeds.baseURLText == "https://api.openai.com/v1")
        #expect(seeds.maxContextText == "200000")
        // "Thinking enabled by default" for Custom — the user can't
        // know their endpoint's capability ahead of time.
        #expect(seeds.supportsThinking == true)
    }

    @Test("Unknown providerID falls through to Custom seeds")
    func unknownProviderFallsBack() {
        let seeds = SettingsModelDetailPane.makeCreateSeeds(providerID: "vapor-cloud-9000")
        #expect(seeds.providerID == LLMProviderCatalog.customProviderID)
        #expect(seeds.modelId == "")
    }
}
