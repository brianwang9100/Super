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

    @Test("Model ids are unique across all providers")
    func modelIdsAreUniqueAcrossProviders() {
        // First-match semantics in `LLMProviderCatalog.model(forModelId:)`
        // mean a collision would silently misattribute a row to the
        // first-listed provider — then trailing-slash URL matching
        // would likely fail and the row would silently reclassify
        // as Custom on edit. Hold the invariant explicitly.
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

    @Test("Every non-Apple, non-Custom provider has a non-nil defaultBaseURL")
    func openAICompatProvidersHaveURL() {
        for entry in LLMProviderCatalog.all {
            if entry.id == LLMProviderCatalog.appleProviderID { continue }
            if entry.id == LLMProviderCatalog.customProviderID { continue }
            #expect(entry.defaultBaseURL != nil, "provider \(entry.id) needs a defaultBaseURL")
        }
    }

    @Test("Apple uses .appleFoundation, Google defaults to native Gemini, everyone else .openAICompatible")
    func providerKindsMatchExpectations() {
        for entry in LLMProviderCatalog.all {
            switch entry.id {
            case LLMProviderCatalog.appleProviderID:
                #expect(entry.kind == .appleFoundation)
            case "google":
                // Google defaults to the native Gemini adapter so Gemini 3
                // thinking models can round-trip tool-call thought signatures.
                #expect(entry.kind == .geminiNative, "Google should default to native Gemini")
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

    /// The OpenAI compat (`defaultBaseURL`) and native (`nativeSearchBaseURL`)
    /// base URLs are byte-identical — both are `https://api.openai.com/v1`.
    /// That collision is the whole reason `resolveEditProvider` classifies
    /// `.openAIResponses` rows by kind before URL-matching. Pin the equality
    /// so a future edit that diverges one constant (and would quietly defuse
    /// the collision the kind-first guard exists to handle) trips here and
    /// forces the §11a PR3a note to be revisited.
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
        #expect(result?.model.displayName == "Gemini 3 Pro")
        #expect(result?.model.maxContextTokens == 1_000_000)
    }

    @Test("model(forModelId:) returns nil for an unknown wire id")
    func modelLookupMiss() {
        #expect(LLMProviderCatalog.model(forModelId: "totally-made-up-2027") == nil)
    }

    // MARK: - URL standardization (slash drift)

    @Test("urlsMatchIgnoringTrailingSlash treats `…/openai` and `…/openai/` as equal")
    func urlsMatchIgnoresTrailingSlash() throws {
        // Edit-mode disambiguation in `SettingsModelDetailPane.init`
        // calls this helper to decide whether a row's stored URL
        // matches a catalog entry. A row persisted under an older
        // code path with the trailing slash dropped (e.g.
        // `…/openai`) must still be recognised as the built-in entry
        // — otherwise edit mode classifies it as Custom and Save
        // re-persists the drifted URL, locking the bug in.
        let anthropic = try #require(LLMProviderCatalog.entry(forID: "anthropic"))
        let canonical = try #require(anthropic.defaultBaseURL)
        let noSlash = try #require(
            URL(string: canonical.absoluteString.hasSuffix("/")
                ? String(canonical.absoluteString.dropLast())
                : canonical.absoluteString + "/")
        )
        #expect(SettingsModelDetailPane.urlsMatchIgnoringTrailingSlash(canonical, noSlash))
        // Different host must still NOT match.
        let other = try #require(URL(string: "https://api.openai.com/v1/openai/"))
        #expect(!SettingsModelDetailPane.urlsMatchIgnoringTrailingSlash(canonical, other))
        // Two nils match; one-side-nil does not.
        #expect(SettingsModelDetailPane.urlsMatchIgnoringTrailingSlash(nil, nil))
        #expect(!SettingsModelDetailPane.urlsMatchIgnoringTrailingSlash(canonical, nil))
    }

    // MARK: - Edit-mode provider resolution

    @Test("resolveEditProvider maps a native-kind row back to its declaring provider by kind, not URL")
    func resolveEditProviderNativeKindByKind() {
        // An `.openAIResponses` row's baseURL (api.openai.com/v1) is
        // byte-identical to the OpenAI compat entry's defaultBaseURL, so the
        // mapping must be by kind, not URL. Now that the web-search picker
        // ships, a native row resolves to the provider entry that *declares*
        // this native adapter ("openai") with its model selected, so the edit
        // form opens in OpenAI with "Native (OpenAI)" chosen and round-trips
        // the native kind on Save (rather than the old Custom fallback).
        #expect(LLMProviderKind.openAIResponses.hasProviderAdapter)
        let resolved = SettingsModelDetailPane.resolveEditProvider(
            kind: .openAIResponses,
            modelId: "gpt-5.5",
            baseURL: URL(string: "https://api.openai.com/v1")
        )
        #expect(resolved.providerID == "openai")
        #expect(resolved.catalogID == "gpt-5.5")
    }

    /// A native row resolves to the provider entry that declares its adapter —
    /// which, for OpenAI, *is* the "openai" entry (it carries both the compat
    /// kind and `nativeSearchAdapter: .openAIResponses`). What keeps Save from
    /// silently downgrading it to compat is the Web search picker, seeded to
    /// "native" from the row's `searchBackend`. This test pins the kind-first
    /// mapping (never a URL match into some *other* provider) and that the
    /// model id carries through so the edit header resolves.
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

    @Test("resolveEditProvider keeps the compat URL-match for an .openAICompatible row")
    func resolveEditProviderCompatStillMatchesByURL() {
        // The same wire id + the catalog base URL on an .openAICompatible
        // row must still resolve to the built-in provider — the kind-first
        // guard only diverts the native kinds.
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
            modelId: "legacy-afm-id",   // off-catalog id still maps to Apple
            baseURL: nil
        )
        #expect(resolved.providerID == LLMProviderCatalog.appleProviderID)
        #expect(resolved.catalogID == "system-default")
    }

    @Test("resolveEditProvider falls back to Custom for an off-catalog compat row")
    func resolveEditProviderCustomFallback() {
        // A catalog wire id pointed at a user's own proxy must stay Custom so
        // Save doesn't re-URL it to the catalog default.
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
        // AFM has no URL — the field isn't rendered for this provider.
        #expect(seeds.baseURLText == "")
    }

    @Test("Google seeds Gemini 3 Pro with the native generateContent URL")
    func googleSeeds() {
        let seeds = SettingsModelDetailPane.makeCreateSeeds(providerID: "google")
        #expect(seeds.name == "Gemini 3 Pro")
        #expect(seeds.modelId == "gemini-3-pro")
        // Google defaults to the native Gemini base (not the /openai/ shim).
        #expect(seeds.baseURLText == "https://generativelanguage.googleapis.com/v1beta")
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
