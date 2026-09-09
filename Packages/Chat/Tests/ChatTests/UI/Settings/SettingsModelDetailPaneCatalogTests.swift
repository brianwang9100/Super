import Core
import Foundation
import Testing
@testable import Chat

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

    @Test("Model ids are unique across all providers")
    func modelIdsAreUniqueAcrossProviders() {
        // First-match lookup would misattribute duplicate model IDs to another provider.
        let ids = LLMProviderCatalog.all.flatMap { $0.models.map(\.id) }
        #expect(Set(ids).count == ids.count, "duplicate model ids across providers: \(ids)")
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

    @Test("Every non-Apple catalog model renders its wire id — no curated display names")
    func modelDisplayNamesAreWireIDs() {
        // Match live-fetched labels by using wire IDs. Apple has no live list and
        // its internal system-default token needs a display name.
        for entry in LLMProviderCatalog.all where entry.id != LLMProviderCatalog.appleProviderID {
            for model in entry.models {
                #expect(
                    model.displayName == model.id,
                    "\(entry.id)/\(model.id) carries a curated displayName (\(model.displayName))"
                )
            }
        }
    }

    @Test("Anthropic shim defaultBaseURL and anthropicNativeBaseURL share a host")
    func anthropicShimAndNativeHostsAgree() {
        // Listing reroutes the shim by host; these independently editable URLs must agree.
        let anthropic = LLMProviderCatalog.entry(forID: "anthropic")
        #expect(
            anthropic?.defaultBaseURL?.host()?.lowercased()
                == LLMProviderCatalog.anthropicNativeBaseURL.host()?.lowercased()
        )
    }

    @Test("Every non-Apple, non-Custom provider has a non-nil defaultBaseURL")
    func openAICompatProvidersHaveURL() {
        for entry in LLMProviderCatalog.all {
            if entry.id == LLMProviderCatalog.appleProviderID { continue }
            if entry.id == LLMProviderCatalog.customProviderID { continue }
            #expect(entry.defaultBaseURL != nil, "provider \(entry.id) needs a defaultBaseURL")
        }
    }

    @Test("Apple → .appleFoundation, Google + Anthropic default to native, everyone else .openAICompatible")
    func providerKindsMatchExpectations() {
        for entry in LLMProviderCatalog.all {
            switch entry.id {
            case LLMProviderCatalog.appleProviderID:
                #expect(entry.kind == .appleFoundation)
            case "google":
                #expect(entry.kind == .geminiNative, "Google should default to native Gemini")
            case "anthropic":
                // Native Messages enables explicit cache_control breakpoints.
                #expect(entry.kind == .anthropicNative, "Anthropic should default to native Messages")
            default:
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

    // MARK: - Native web-search adapters

    @Test("Native-search providers map to the right adapter kind + base URL")
    func nativeSearchAdaptersMatchExpectations() throws {
        let openai = try #require(LLMProviderCatalog.entry(forID: "openai"))
        #expect(openai.nativeSearchAdapter == .openAIResponses)
        #expect(openai.nativeSearchBaseURL?.absoluteString == "https://api.openai.com/v1")
        #expect(openai.supportsNativeSearch)

        let anthropic = try #require(LLMProviderCatalog.entry(forID: "anthropic"))
        #expect(anthropic.nativeSearchAdapter == .anthropicNative)
        #expect(anthropic.nativeSearchBaseURL?.absoluteString == "https://api.anthropic.com/v1")
        #expect(anthropic.supportsNativeSearch)

        let google = try #require(LLMProviderCatalog.entry(forID: "google"))
        #expect(google.nativeSearchAdapter == .geminiNative)
        #expect(google.nativeSearchBaseURL?.absoluteString == "https://generativelanguage.googleapis.com/v1beta")
        #expect(google.supportsNativeSearch)
    }

    /// Identical compat/native URLs require kind-first edit classification.
    @Test("OpenAI compat and native base URLs are intentionally identical")
    func openAICompatAndNativeBaseURLsCollide() throws {
        let openai = try #require(LLMProviderCatalog.entry(forID: "openai"))
        #expect(openai.defaultBaseURL == openai.nativeSearchBaseURL)
    }

    @Test("Providers without a native adapter expose nil + supportsNativeSearch == false")
    func providersWithoutNativeSearch() {
        for id in [LLMProviderCatalog.appleProviderID, "xai", LLMProviderCatalog.customProviderID] {
            let entry = LLMProviderCatalog.entry(forID: id)
            #expect(entry?.nativeSearchAdapter == nil, "\(id) should have no native adapter")
            #expect(entry?.nativeSearchBaseURL == nil, "\(id) should have no native base URL")
            #expect(entry?.supportsNativeSearch == false, "\(id) should not support native search")
        }
    }

    @Test("nativeSearchBaseURL is non-nil exactly when nativeSearchAdapter is")
    func nativeSearchFieldsArePaired() {
        for entry in LLMProviderCatalog.all {
            #expect(
                (entry.nativeSearchAdapter == nil) == (entry.nativeSearchBaseURL == nil),
                "provider \(entry.id): adapter/baseURL nullability must agree"
            )
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
        #expect(result?.model.displayName == "gemini-3-pro")
        #expect(result?.model.maxContextTokens == 1_000_000)
    }

    @Test("model(forModelId:) returns nil for an unknown wire id")
    func modelLookupMiss() {
        #expect(LLMProviderCatalog.model(forModelId: "totally-made-up-2027") == nil)
    }

    // MARK: - URL standardization (slash drift)

    @Test("urlsMatchIgnoringTrailingSlash treats `…/openai` and `…/openai/` as equal")
    func urlsMatchIgnoresTrailingSlash() throws {
        // Legacy trailing-slash differences must not reclassify built-in rows as Custom.
        let anthropic = try #require(LLMProviderCatalog.entry(forID: "anthropic"))
        let canonical = try #require(anthropic.defaultBaseURL)
        let noSlash = try #require(
            URL(string: canonical.absoluteString.hasSuffix("/")
                ? String(canonical.absoluteString.dropLast())
                : canonical.absoluteString + "/")
        )
        #expect(SettingsModelDetailPane.urlsMatchIgnoringTrailingSlash(canonical, noSlash))
        let other = try #require(URL(string: "https://api.openai.com/v1/openai/"))
        #expect(!SettingsModelDetailPane.urlsMatchIgnoringTrailingSlash(canonical, other))
        #expect(SettingsModelDetailPane.urlsMatchIgnoringTrailingSlash(nil, nil))
        #expect(!SettingsModelDetailPane.urlsMatchIgnoringTrailingSlash(canonical, nil))
    }

    // MARK: - Edit-mode provider resolution

    @Test("resolveEditProvider maps a native-kind row back to its declaring provider by kind, not URL")
    func resolveEditProviderNativeKindByKind() {
        #expect(LLMProviderKind.openAIResponses.hasProviderAdapter)
        let resolved = SettingsModelDetailPane.resolveEditProvider(
            kind: .openAIResponses,
            modelId: "gpt-5.5",
            baseURL: URL(string: "https://api.openai.com/v1")
        )
        #expect(resolved.providerID == "openai")
        #expect(resolved.catalogID == "gpt-5.5")
    }

    @Test("resolveEditProvider maps each native kind to its declaring catalog entry")
    func resolveEditProviderNativeKindsMapToDeclaringEntry() {
        let openai = SettingsModelDetailPane.resolveEditProvider(
            kind: .openAIResponses, modelId: "gpt-5.5",
            baseURL: URL(string: "https://api.openai.com/v1")
        )
        #expect(openai.providerID == "openai")
        #expect(openai.catalogID == "gpt-5.5")

        let anthropic = SettingsModelDetailPane.resolveEditProvider(
            kind: .anthropicNative, modelId: "claude-opus-4-7",
            baseURL: URL(string: "https://api.anthropic.com/v1")
        )
        #expect(anthropic.providerID == "anthropic")
        #expect(anthropic.catalogID == "claude-opus-4-7")

        let google = SettingsModelDetailPane.resolveEditProvider(
            kind: .geminiNative, modelId: "gemini-3-pro",
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")
        )
        #expect(google.providerID == "google")
        #expect(google.catalogID == "gemini-3-pro")
    }

    @Test("a flipped default Anthropic native row opens to the Anthropic provider")
    func resolveEditProviderDefaultAnthropicNativeRow() {
        let entry = LLMProviderCatalog.entry(forID: "anthropic")
        #expect(entry?.kind == .anthropicNative)
        #expect(entry?.defaultBaseURL == URL(string: "https://api.anthropic.com/v1"))
        let resolved = SettingsModelDetailPane.resolveEditProvider(
            kind: .anthropicNative,
            modelId: "claude-opus-4-7",
            baseURL: entry?.defaultBaseURL
        )
        #expect(resolved.providerID == "anthropic")
        #expect(resolved.catalogID == "claude-opus-4-7")
    }

    @Test("resolveEditProvider keeps the compat URL-match for an .openAICompatible row")
    func resolveEditProviderCompatStillMatchesByURL() {
        let entry = LLMProviderCatalog.entry(forID: "openai")
        let resolved = SettingsModelDetailPane.resolveEditProvider(
            kind: .openAICompatible,
            modelId: "gpt-5.5",
            baseURL: entry?.defaultBaseURL
        )
        #expect(resolved.providerID == "openai")
        #expect(resolved.catalogID == "gpt-5.5")
    }

    @Test("resolveEditProvider resolves an .appleFoundation row by kind")
    func resolveEditProviderApple() {
        let resolved = SettingsModelDetailPane.resolveEditProvider(
            kind: .appleFoundation,
            modelId: "legacy-afm-id",
            baseURL: nil
        )
        #expect(resolved.providerID == LLMProviderCatalog.appleProviderID)
        #expect(resolved.catalogID == "system-default")
    }

    @Test("resolveEditProvider falls back to Custom for an off-catalog compat row")
    func resolveEditProviderCustomFallback() {
        // Preserve custom proxy URLs when saving catalog model IDs.
        let resolved = SettingsModelDetailPane.resolveEditProvider(
            kind: .openAICompatible,
            modelId: "gpt-5.5",
            baseURL: URL(string: "https://my-proxy.local/v1")
        )
        #expect(resolved.providerID == LLMProviderCatalog.customProviderID)
        #expect(resolved.catalogID == "")
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
        #expect(seeds.baseURLText == "")
    }

    @Test("Apple provider reads 'Apple'; its model reads 'Apple Intelligence'")
    func appleProviderAndModelNamesAreDistinct() {
        let entry = LLMProviderCatalog.entry(forID: LLMProviderCatalog.appleProviderID)
        #expect(entry?.displayName == "Apple", "provider should mirror Google/Gemini — provider name is 'Apple'")
        #expect(entry?.kind == .appleFoundation)
        #expect(entry?.models.count == 1)
        #expect(entry?.models.first?.displayName == "Apple Intelligence", "the single model is 'Apple Intelligence'")
    }

    @Test("Google seeds Gemini 3 Pro with the native generateContent URL")
    func googleSeeds() {
        let seeds = SettingsModelDetailPane.makeCreateSeeds(providerID: "google")
        #expect(seeds.name == "gemini-3-pro")
        #expect(seeds.modelId == "gemini-3-pro")
        #expect(seeds.baseURLText == "https://generativelanguage.googleapis.com/v1beta")
        #expect(seeds.maxContextText == "1000000")
        #expect(seeds.supportsThinking == true)
    }

    @Test("OpenAI seeds GPT-5.5 by default")
    func openAISeeds() {
        let seeds = SettingsModelDetailPane.makeCreateSeeds(providerID: "openai")
        #expect(seeds.name == "gpt-5.5")
        #expect(seeds.modelId == "gpt-5.5")
        #expect(seeds.baseURLText == "https://api.openai.com/v1")
        #expect(seeds.maxContextText == "1000000")
        #expect(seeds.supportsThinking == true)
    }

    @Test("Anthropic seeds Opus 4.7 with the native Messages base URL and thinking ON")
    func anthropicSeeds() {
        let seeds = SettingsModelDetailPane.makeCreateSeeds(providerID: "anthropic")
        #expect(seeds.name == "claude-opus-4-7")
        #expect(seeds.modelId == "claude-opus-4-7")
        #expect(seeds.baseURLText == "https://api.anthropic.com/v1")
        #expect(seeds.maxContextText == "1000000")
        #expect(seeds.supportsThinking == true)
    }

    @Test("xAI seeds Grok 4.3 with thinking ON by default")
    func xaiSeeds() {
        let seeds = SettingsModelDetailPane.makeCreateSeeds(providerID: "xai")
        #expect(seeds.name == "grok-4.3")
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
        #expect(seeds.supportsThinking == true)
    }

    @Test("Unknown providerID falls through to Custom seeds")
    func unknownProviderFallsBack() {
        let seeds = SettingsModelDetailPane.makeCreateSeeds(providerID: "vapor-cloud-9000")
        #expect(seeds.providerID == LLMProviderCatalog.customProviderID)
        #expect(seeds.modelId == "")
    }

    // MARK: - reconcile (live model list ⨉ catalog metadata)

    @Test("A fetched id matching the catalog keeps its curated metadata")
    func reconcileKnownKeepsCatalogMetadata() {
        let merged = LLMProviderCatalog.reconcile(
            providerID: "openai",
            fetchedModelIDs: ["gpt-5.5"]
        )
        #expect(merged.count == 1)
        let model = merged[0]
        #expect(model.id == "gpt-5.5")
        #expect(model.displayName == "gpt-5.5")
        #expect(model.maxContextTokens == 1_000_000)
        #expect(model.supportsThinking == true)
    }

    @Test("A fetched id with no catalog entry gets editable defaults")
    func reconcileUnknownGetsDefaults() {
        let merged = LLMProviderCatalog.reconcile(
            providerID: "openai",
            fetchedModelIDs: ["gpt-6-preview"]
        )
        #expect(merged.count == 1)
        let model = merged[0]
        #expect(model.id == "gpt-6-preview")
        #expect(model.displayName == "gpt-6-preview")
        #expect(model.maxContextTokens == LLMProviderCatalog.defaultFetchedMaxContextTokens)
        #expect(model.supportsThinking == false)
    }

    @Test("Known ids sort first in catalog order, unknown ids alphabetically after")
    func reconcileOrdersCuratedFirst() {
        let merged = LLMProviderCatalog.reconcile(
            providerID: "openai",
            fetchedModelIDs: ["zeta-model", "gpt-5.4-mini", "alpha-model", "gpt-5.5"]
        )
        let ids = merged.map(\.id)
        #expect(ids == ["gpt-5.5", "gpt-5.4-mini", "alpha-model", "zeta-model"])
    }

    @Test("Duplicate fetched ids collapse to a single entry")
    func reconcileDedupesFetched() {
        let merged = LLMProviderCatalog.reconcile(
            providerID: "openai",
            fetchedModelIDs: ["gpt-5.5", "gpt-5.5", "dup-x", "dup-x"]
        )
        #expect(merged.map(\.id) == ["gpt-5.5", "dup-x"])
    }

    @Test("An unknown providerID treats every fetched id as a default model")
    func reconcileUnknownProvider() {
        let merged = LLMProviderCatalog.reconcile(
            providerID: "vapor-cloud-9000",
            fetchedModelIDs: ["b-model", "a-model"]
        )
        #expect(merged.map(\.id) == ["a-model", "b-model"])
        #expect(merged.allSatisfy { $0.maxContextTokens == LLMProviderCatalog.defaultFetchedMaxContextTokens })
    }

    @Test("An empty fetch yields an empty list (caller falls back to catalog)")
    func reconcileEmptyFetch() {
        let merged = LLMProviderCatalog.reconcile(providerID: "openai", fetchedModelIDs: [])
        #expect(merged.isEmpty)
    }

    // MARK: - Key-first create-flow gating

    @Test("Gated create fields hide only for a built-in non-Apple provider with an empty key")
    func gatedCreateFieldsTruthTable() {
        #expect(!SettingsModelDetailPane.showsGatedCreateFields(
            isEditing: false, isApple: false, isCustom: false, trimmedKeyEmpty: true
        ))
        #expect(SettingsModelDetailPane.showsGatedCreateFields(
            isEditing: false, isApple: false, isCustom: false, trimmedKeyEmpty: false
        ))
        #expect(SettingsModelDetailPane.showsGatedCreateFields(
            isEditing: false, isApple: true, isCustom: false, trimmedKeyEmpty: true
        ))
        #expect(SettingsModelDetailPane.showsGatedCreateFields(
            isEditing: false, isApple: false, isCustom: true, trimmedKeyEmpty: true
        ))
        #expect(SettingsModelDetailPane.showsGatedCreateFields(
            isEditing: true, isApple: false, isCustom: false, trimmedKeyEmpty: true
        ))
    }

    // MARK: - xAI catalog

    @Test("xAI's catalog carries only Grok 4.3 — grok-4.1-fast was deprecated and pruned")
    func xaiCatalogPrunedDeprecated() {
        let entry = LLMProviderCatalog.entry(forID: "xai")
        #expect(entry?.models.map(\.id) == ["grok-4.3"])
    }

    // MARK: - Edit-mode model editing

    @Test("resolveEditProvider keeps the raw wire id for an off-catalog native row")
    func resolveEditProviderOffCatalogNativeKeepsWireId() {
        // Retain pruned model IDs or untouched rows lose their selection and cannot be saved.
        let resolved = SettingsModelDetailPane.resolveEditProvider(
            kind: .geminiNative,
            modelId: "gemini-2.5-pro",
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")
        )
        #expect(resolved.providerID == "google")
        #expect(resolved.catalogID == "gemini-2.5-pro")
    }

    @Test("editSeedName heals an empty name from the catalog model or the stored fallback")
    func editSeedNameHealsEmptyNames() {
        #expect(SettingsModelDetailPane.editSeedName(
            rowName: "My Gemini", resolvedProviderID: "google",
            resolvedCatalogID: "gemini-3-pro", storedFallback: nil
        ) == "My Gemini")
        #expect(SettingsModelDetailPane.editSeedName(
            rowName: "  ", resolvedProviderID: "google",
            resolvedCatalogID: "gemini-3-pro", storedFallback: nil
        ) == "gemini-3-pro")
        // Built-in names are hidden; heal missing names so Save remains reachable.
        let fallback = LLMCatalogModel(
            id: "gemini-2.5-pro", displayName: "gemini-2.5-pro",
            maxContextTokens: 1_000_000, supportsThinking: true
        )
        #expect(SettingsModelDetailPane.editSeedName(
            rowName: "", resolvedProviderID: "google",
            resolvedCatalogID: "gemini-2.5-pro", storedFallback: fallback
        ) == "gemini-2.5-pro")
        #expect(SettingsModelDetailPane.editSeedName(
            rowName: "", resolvedProviderID: LLMProviderCatalog.customProviderID,
            resolvedCatalogID: "", storedFallback: nil
        ) == "")
    }

    @Test("Edit header is provider-only for built-ins, Provider · Model for Apple, nil for Custom/create")
    func editHeaderLabelTruthTable() {
        #expect(SettingsModelDetailPane.editHeaderLabel(
            isEditing: true, isApple: false, isCustom: false,
            providerName: "OpenAI", modelName: "GPT-5.5"
        ) == "OpenAI")
        #expect(SettingsModelDetailPane.editHeaderLabel(
            isEditing: true, isApple: false, isCustom: false,
            providerName: "Google", modelName: nil
        ) == "Google")
        #expect(SettingsModelDetailPane.editHeaderLabel(
            isEditing: true, isApple: true, isCustom: false,
            providerName: "Apple", modelName: "Apple Intelligence"
        ) == "Apple · Apple Intelligence")
        #expect(SettingsModelDetailPane.editHeaderLabel(
            isEditing: true, isApple: false, isCustom: true,
            providerName: "Custom", modelName: nil
        ) == nil)
        #expect(SettingsModelDetailPane.editHeaderLabel(
            isEditing: false, isApple: false, isCustom: false,
            providerName: "OpenAI", modelName: "GPT-5.5"
        ) == nil)
    }

    @Test("makeStoredModelFallback prefers curated metadata, synthesizes for off-catalog ids")
    func makeStoredModelFallbackPrefersCuratedMetadata() {
        let curated = SettingsModelDetailPane.makeStoredModelFallback(
            resolvedProviderID: "google", modelId: "gemini-3-pro",
            maxContextTokens: 8_192, supportsThinking: true
        )
        #expect(curated?.displayName == "gemini-3-pro")
        #expect(curated?.maxContextTokens == 1_000_000)

        // Never cap an existing large-window row below its stored value and disable Save.
        let bigStored = SettingsModelDetailPane.makeStoredModelFallback(
            resolvedProviderID: "google", modelId: "gemini-2.5-pro",
            maxContextTokens: 1_000_000, supportsThinking: true
        )
        #expect(bigStored?.displayName == "gemini-2.5-pro")
        #expect(bigStored?.maxContextTokens == 1_000_000)
        #expect(bigStored?.supportsThinking == true)
        let smallStored = SettingsModelDetailPane.makeStoredModelFallback(
            resolvedProviderID: "google", modelId: "gemini-2.5-flash-lite",
            maxContextTokens: 8_192, supportsThinking: false
        )
        #expect(smallStored?.maxContextTokens == LLMProviderCatalog.defaultFetchedMaxContextTokens)

        #expect(SettingsModelDetailPane.makeStoredModelFallback(
            resolvedProviderID: LLMProviderCatalog.customProviderID,
            modelId: "anything", maxContextTokens: 1, supportsThinking: false
        ) == nil)
        #expect(SettingsModelDetailPane.makeStoredModelFallback(
            resolvedProviderID: LLMProviderCatalog.appleProviderID,
            modelId: "system-default", maxContextTokens: 1, supportsThinking: false
        ) == nil)
        #expect(SettingsModelDetailPane.makeStoredModelFallback(
            resolvedProviderID: "google", modelId: "",
            maxContextTokens: 1, supportsThinking: false
        ) == nil)
    }

    @Test("displayedModels unions the stored model into whichever base list omits it")
    func displayedModelsUnionsStoredModel() {
        let stored = LLMCatalogModel(
            id: "gemini-2.5-pro", displayName: "gemini-2.5-pro",
            maxContextTokens: 1_000_000, supportsThinking: true
        )
        let fetched = [LLMCatalogModel(
            id: "gemini-3-pro", displayName: "Gemini 3 Pro",
            maxContextTokens: 1_000_000, supportsThinking: true
        )]

        let unioned = SettingsModelDetailPane.displayedModels(
            fetched: fetched, catalog: [], storedFallback: stored
        )
        #expect(unioned.map(\.id) == ["gemini-3-pro", "gemini-2.5-pro"])

        let catalogBase = SettingsModelDetailPane.displayedModels(
            fetched: nil, catalog: fetched, storedFallback: stored
        )
        #expect(catalogBase.map(\.id) == ["gemini-3-pro", "gemini-2.5-pro"])

        let createMode = SettingsModelDetailPane.displayedModels(
            fetched: fetched, catalog: [], storedFallback: nil
        )
        #expect(createMode.map(\.id) == ["gemini-3-pro"])
    }

    @Test("displayedModels replaces a live-listed stored id with the fallback's authoritative metadata")
    func displayedModelsReplacesLiveListedStoredModel() {
        // A live off-catalog match has default metadata. Prefer stored capabilities
        // or an untouched row can lose Thinking support or fail the Save cap check.
        let stored = LLMCatalogModel(
            id: "gemini-2.5-pro", displayName: "gemini-2.5-pro",
            maxContextTokens: 1_000_000, supportsThinking: true
        )
        let fetched = LLMProviderCatalog.reconcile(
            providerID: "google",
            fetchedModelIDs: ["gemini-3-pro", "gemini-2.5-pro"]
        )
        let synthesized = fetched.first { $0.id == "gemini-2.5-pro" }
        #expect(synthesized?.maxContextTokens == LLMProviderCatalog.defaultFetchedMaxContextTokens)
        #expect(synthesized?.supportsThinking == false)

        let displayed = SettingsModelDetailPane.displayedModels(
            fetched: fetched, catalog: [], storedFallback: stored
        )
        #expect(displayed.map(\.id) == ["gemini-3-pro", "gemini-2.5-pro"])
        let resolved = displayed.first { $0.id == "gemini-2.5-pro" }
        #expect(resolved?.maxContextTokens == 1_000_000)
        #expect(resolved?.supportsThinking == true)
    }
}
