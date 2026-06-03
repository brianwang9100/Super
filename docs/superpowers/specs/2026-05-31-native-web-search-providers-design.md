
# Native Web Search Providers — Engineering Design Spec

> Add native **server-side web search** to the three hosted LLM providers — **Anthropic Claude** (Messages API `web_search` tool), **Google Gemini** (`generateContent` `google_search` grounding), and **OpenAI** (Responses API `web_search` tool). This is "Engine A / Phase 2" of the web-search feature (`~/.claude/plans/lexical-bouncing-toast.md`); Engine B (standalone Tavily/Brave client tool) is a separate track. Each native provider becomes a **full** `LLMProvider` (text + thinking + regular tool calls + native search + citations).

**Status (2026-05-31):** Design draft. Not yet implemented. Higher-level plan locked; this is the deep technical spec for the native-adapter portion. **Re-sequenced: native is Phase 1 (ships first); standalone Tavily/Brave is Phase 2** — the §-text below still says "Engine A / Phase 2" in places; read it as "native, ships first."

## 0. Resolved decisions (2026-05-31) — supersede the open questions in §11

1. **Spec location:** `docs/superpowers/specs/` (this file). ✓
2. **Cost-gate frequency:** **prompt before EVERY search** (no per-conversation auto-allow). The global "Ask before each search" toggle (default ON) is the only escape hatch. §7's per-conversation "compromise" is **rejected**; each search re-runs the proposal round-trip.
3. **Anthropic tool version:** ship **`web_search_20260209`** (dynamic filtering), NOT `web_search_20250305`. Constant `anthropicWebSearchToolType = "web_search_20260209"`. ⚠️ This version is **model-gated** (Opus 4.6+/Sonnet 4.6+) and requires the **code-execution tool enabled** in the request — the adapter must add the code-execution tool alongside `web_search`, and the Add-Model dropdown must only offer `Native (Anthropic)` for capable models (gate on the catalog model's capability; otherwise hide/disable the native option). Replace every `web_search_20250305` reference below accordingly.
4. **SuperOS routing:** native search calls go **direct device→provider** (same as SuperBible, same as current LLM calls). No backend proxy.
5. **`SourceCitation`:** single Core type, shared by both engines, with `providerEcho` (§4.1). ✓ accepted.
6. **`.searchResult` `LLMContent`:** accepted (§4.3) — travels through the existing `messages` array; no side channel.
7. **Anthropic `max_tokens`:** derive as `min(maxContextTokens / 4, 4096)` (not a fixed cap).
8. **Gemini WebView snapshots:** container-only snapshots + logic unit tests + manual render verification (no golden PNG).
9. **Gemini `google_search` + client tools:** route client tools through the gated re-issue flow (search-only on the native-search turn); revisit only if a real model needs both at once.

**Related:** `~/.claude/plans/lexical-bouncing-toast.md` (locked decisions), `docs/MOBILE_ARCHITECTURE.md` (LLM adapter, tool system), `docs/Chat/`, `docs/superpowers/specs/2026-05-23-superbible-fork-design.md` (format sibling), root `AGENTS.md`, `Packages/Core/CLAUDE.md`, `Packages/Chat/CLAUDE.md`.

---

## 1. Why native search needs new adapters

Every hosted model in Super today flows through **one** provider: `OpenAICompatibleLLMProvider` (`Packages/Chat/Sources/Chat/LLM/OpenAICompatibleLLMProvider.swift`), an OpenAI-Chat-Completions client. OpenAI uses it directly; **Anthropic and Google reach it through their `/openai/` compatibility shims** (`anthropicOpenAIShimBaseURL = https://api.anthropic.com/v1/openai`, `googleBaseURL = https://generativelanguage.googleapis.com/v1beta/openai` in `LLMProviderCatalog`). That path structurally cannot carry native search — verified in-tree:

1. **Tools are hardcoded to functions.** `OpenAIWireTypes.swift`'s `OpenAITool` is `let type = "function"` (init sets it unconditionally). There is no field for a server-side tool descriptor (`web_search_20250305`, `{"google_search":{}}`, `{"type":"web_search"}`).
2. **No citation channel.** `OpenAIStreamChunk` / `OpenAIStreamChoice` / `OpenAIDelta` decode only `content`, `reasoning(_content)`, `tool_calls`, `finish_reason`, `usage`. Nowhere for citations, grounding chunks, or `searchEntryPoint` HTML.
3. **The compat shims drop native features.** Anthropic's `/openai/` shim and Google's OpenAI surface do not expose `web_search` / `google_search` grounding — those live only on the **native** Messages / `generateContent` / Responses endpoints.
4. **`LLMStreamEvent` has no search/citation case.** The real enum (`Packages/Core/Sources/Core/LLM/LLMStreamEvent.swift`) is `messageStart / contentBlockStart / textDelta / thinkingDelta / toolUse / contentBlockStop / messageComplete / error` — all indexed. Citations have no home.

Per the locked plan, a native adapter is instantiated for a model **only when `searchBackend == "native"`**; otherwise the model keeps `OpenAICompatibleLLMProvider`. Once a turn is on the native API there is **no per-message fallback**, so each native adapter must also handle normal text, thinking, and regular client tool calls — it is a complete provider, not a search-only shim.

### Confirmed current API shapes (verified 2026-05-31; training data is stale on exact shapes)

- **Anthropic `web_search`** — tool `{"type":"web_search_20250305","name":"web_search","max_uses":N}`; endpoint `POST https://api.anthropic.com/v1/messages`; auth header **`x-api-key`** (not Bearer) + `anthropic-version: 2023-06-01`; `max_tokens` **required**. Streams a `server_tool_use` block (query via `input_json_delta`), a `web_search_tool_result` block (`results[]` each `{type:"web_search_result", url, title, encrypted_content, page_age}`), and `text` blocks whose `citations` arrive via `citations_delta` as `web_search_result_location` `{url, title, encrypted_index, cited_text}`. **`encrypted_content` + `encrypted_index` MUST round-trip verbatim across turns.** Docs: https://docs.anthropic.com/en/docs/build-with-claude/tool-use/web-search-tool , https://docs.anthropic.com/en/docs/build-with-claude/streaming
- **Gemini `google_search`** — `tools:[{"google_search":{}}]` on `POST .../v1beta/models/{model}:streamGenerateContent?alt=sse`; system prompt goes in `systemInstruction` (no system role). Response `groundingMetadata`: `webSearchQueries[]`, `groundingChunks[].web.{uri,title}`, `groundingSupports[].{segment:{startIndex,endIndex,text}, groundingChunkIndices[]}`, `searchEntryPoint.renderedContent` (HTML+CSS). **Mandatory display compliance:** `renderedContent` ("Google Search Suggestions") must be shown **unmodified** whenever a grounded response is shown. Docs: https://ai.google.dev/gemini-api/docs/google-search , https://ai.google.dev/gemini-api/docs/grounding
- **OpenAI Responses `web_search`** — `POST https://api.openai.com/v1/responses`; auth `Authorization: Bearer`; `tools:[{"type":"web_search"}]` (legacy alias `web_search_preview`); request uses `input` + optional `instructions`. Typed SSE: `response.output_item.added`, `response.web_search_call.in_progress|searching|completed`, `response.output_text.delta`, `response.output_text.annotation.added` (annotation `url_citation` `{url,title,start_index,end_index}`), `response.reasoning_summary_text.delta`, `response.completed`, `response.error`. No `[DONE]` sentinel. Docs: https://platform.openai.com/docs/guides/tools-web-search , https://platform.openai.com/docs/api-reference/responses-streaming

---

## 2. Goals & non-goals

**Goals**
- Three native `LLMProvider`s (`AnthropicNativeLLMProvider`, `GeminiNativeLLMProvider`, `OpenAIResponsesLLMProvider`), each full (text + thinking + regular tools + native search + citations).
- Backward-compatible `LLMStreamEvent` extension + a shared `SourceCitation` (Core).
- Persist citations to `MessageAttachments.sources` (unified sink shared with Engine B); render a collapsible "N sources" pill.
- Render Gemini `searchEntryPoint` HTML unmodified in `GeminiSearchSuggestionsView`, kept visible alongside the pill.
- Wire the global cost gate ("Ask before each search", default ON) to the autonomous native path.
- Plumb provider-kind discrimination, catalog, hydration, Add-Model settings.
- Tests ship with every change: offline SSE fixtures, reducer unit tests, mocked-provider `ChatSession` tests, snapshot tests, `DebugLLMProvider` sim seam.

**Non-goals**
- Engine B (standalone client search tool) — separate track.
- Migrating the default non-search path off `OpenAICompatibleLLMProvider` (open question §11).
- Server-side LLM proxy — SuperBible is serverless/BYOK; SuperOS proxy posture is open question §11.
- New citation tables — citations ride in the existing `attachmentsJSON` sidecar.

---

## 3. Architecture overview

```
ChatSession (turn loop, cost gate, StreamAccumulator → citation sink)
   │  stream(messages:model:tools:temperature:)
   ▼
LLMProviderRegistry (actor) ── selects active provider by id
   │
   ├─ OpenAICompatibleLLMProvider   (searchBackend != "native"; UNCHANGED)
   ├─ AnthropicNativeLLMProvider    (kind .anthropicNative)
   ├─ GeminiNativeLLMProvider       (kind .geminiNative)
   └─ OpenAIResponsesLLMProvider    (kind .openAIResponses)
        each: http.stream(req) → SSEParser → <Provider>StreamReducer → LLMStreamEvent
              new events: .searchStarted / .citations / .searchSuggestionsHTML
```

The registry, `HTTPClient`, `SSEParser`, the `LLMProvider` protocol, `ChatSession`'s turn loop, and `OpenAICompatibleLLMProvider` are **reused unchanged**. New surface: three providers + wire types + reducers, the `LLMStreamEvent`/`LLMContent` extension, `SourceCitation`, catalog/hydration/settings branches, the cost-gate proposal flow, the citation UI.

---

## 4. Shared plumbing — `LLMStreamEvent` + citation model (PR 1)

### 4.1 `SourceCitation` (Core)

New `Packages/Core/Sources/Core/LLM/SourceCitation.swift`. A struct (data → struct), unified across both engines so the pill renders identically regardless of source. **Field set is harmonized with the Engine-B plan's `SourceCitation`** (the standalone plan lists `id, title, url, snippet, faviconURL, publishedDate`); this spec is authoritative for the native fields and adds `providerEcho`. Land **one** `SourceCitation` type usable by both engines.

```swift
/// A single web source cited in a grounded assistant response, normalized
/// across native providers (Anthropic, Gemini, OpenAI) and the standalone
/// search engine. Persisted in `MessageAttachments.sources`.
public struct SourceCitation: Sendable, Equatable, Codable, Identifiable {
    public let id: String            // stable; derived from url + ordinal when provider gives none
    public let title: String
    public let url: URL
    public let snippet: String?      // Anthropic cited_text / Gemini segment.text; nil otherwise
    public let faviconURL: URL?      // Engine-B may fill; native leaves nil (derive host favicon in UI)
    public let publishedDate: Date?  // Anthropic page_age when parseable; else nil
    /// Opaque provider state that MUST be echoed back on later turns for the
    /// citation to stay valid. Anthropic-only today; nil for Gemini/OpenAI.
    public let providerEcho: ProviderEcho?
    public init(id: String, title: String, url: URL, snippet: String? = nil,
                faviconURL: URL? = nil, publishedDate: Date? = nil,
                providerEcho: ProviderEcho? = nil) { … }
}

/// Opaque, provider-specific data that round-trips across turns. Stored but
/// never inspected by the UI; only the adapter that produced it reads it.
public struct ProviderEcho: Sendable, Equatable, Codable {
    public let kind: String              // e.g. "anthropic.web_search"
    public let encryptedContent: String? // Anthropic web_search_result.encrypted_content
    public let encryptedIndex: String?   // Anthropic citation.encrypted_index
}
```

### 4.2 New `LLMStreamEvent` cases

Append to the enum (it is `Sendable, Equatable`):

```swift
/// A native server-side web search started for the given query.
case searchStarted(query: String)
/// Normalized citations parsed from the stream. May arrive multiple times;
/// ChatSession accumulates and dedupes on url.
case citations([SourceCitation])
/// Provider-supplied search-attribution HTML that MUST be rendered
/// unmodified (Gemini "Google Search Suggestions"). Other providers never emit it.
case searchSuggestionsHTML(String)
```

**Backward-compat:** `ChatSession.streamOneTurn(...)` switches over `LLMStreamEvent` **without a `default`** (cases `.messageStart/.contentBlockStart/.contentBlockStop`, `.textDelta`, `.thinkingDelta`, `.toolUse`, `.messageComplete`, `.error`), so the compiler forces handling the new cases in PR 1 — intentional, keeps consumers honest. `DebugLLMProvider`, the reducer unit tests, and any other exhaustive switches update in the same PR. No existing case changes, so persisted/encoded shapes are untouched.

Three cases, not one: `searchStarted` drives the "Searching the web…" affordance independent of whether citations arrive; `citations` is the persisted payload; `searchSuggestionsHTML` is a Gemini compliance artifact with a different visibility rule (always visible, not collapsible).

### 4.3 New `LLMContent` case (Anthropic round-trip carrier)

Anthropic requires the prior `web_search_tool_result` (incl. `encrypted_content`) and each citation's `encrypted_index` be replayed verbatim. To carry that through the existing `messages: [LLMMessage]` the protocol already passes — without a side channel and without changing the protocol signature — add to `LLMContent`:

```swift
/// Echoed prior-turn web-search results, replayed verbatim so providers that
/// require it (Anthropic) keep citations valid. Carries the opaque
/// per-result/per-citation echo blobs. Ignored by providers that don't need it.
case searchResult([SourceCitation])
```

`OpenAICompatibleLLMProvider.translate(_ messages:)` and the Gemini/OpenAI adapters ignore it (`case .searchResult: continue`); only the Anthropic adapter re-serializes it. `LLMContent` is `Equatable` and gains one case — update the (few) exhaustive switches over `LLMContent` in the same PR.

### 4.4 Landing citations in `MessageAttachments.sources`

The real `MessageAttachments` (`Packages/Chat/Sources/Chat/Models/MessageAttachments.swift`) is a versioned shape carrying `references: [RecordReference]` (Bible verse pills) with `isEmpty { references.isEmpty }`; it is serialized via `MessageRecord.encode(_:)` (returns nil when `isEmpty`, so the column stays NULL) and read back through `MessageRecord.attachments`. Extend it — this is exactly the "future attachment kinds add fields here rather than new columns" path the type's doc comment promises:

```swift
public var references: [RecordReference]        // existing
public var sources: [SourceCitation]            // NEW, default []
public var searchSuggestionsHTML: String?       // NEW, Gemini compliance, default nil
// isEmpty: references.isEmpty && sources.isEmpty && searchSuggestionsHTML == nil
// init gains defaulted sources: [] = [], searchSuggestionsHTML: String? = nil
```

`MessageAttachments` is JSON in `MessageRecord.attachmentsJSON`. Adding **optional/defaulted** fields is forward/backward compatible — `MessageRecord.attachments` decodes with `try?`, and a `Codable` struct with defaulted new fields tolerates old rows missing the keys **only if the synthesized decoder treats them as optional**; since `sources`/`searchSuggestionsHTML` are a defaulted array + optional, give them explicit `decodeIfPresent` handling (a small custom `init(from:)`) so legacy rows decode cleanly. **No GRDB schema migration is needed for citations** — the `attachmentsJSON` column already exists (added by the `v2_messageAttachments` migration).

`ChatSession`'s live-turn accumulators are on `LiveTurn` (currently `accumulatedText`, `accumulatedThinking`, `thinkingStartedAt`, `subscribers`); add `pendingSources: [SourceCitation] = []` and `pendingSuggestionsHTML: String?`. In `streamOneTurn`'s event switch:

```swift
case .searchStarted(let query):
    broadcast(.searchStarted(query: query))     // drives the "Searching the web…" affordance
case .citations(let cites):
    liveTurn?.pendingSources.merge(cites)        // dedupe on url; keep first providerEcho
    broadcast(.citations(cites))
case .searchSuggestionsHTML(let html):
    liveTurn?.pendingSuggestionsHTML = html
    broadcast(.searchSuggestionsHTML(html))
```

(Adding `ChatEvent.searchStarted/.citations/.searchSuggestionsHTML` mirrors the new stream events through Chat's own event channel; `broadcast` already fans out `ChatEvent`s to subscribers.) When the assistant `MessageRecord` is persisted on `.messageComplete`, build `MessageAttachments(references:, sources: liveTurn.pendingSources, searchSuggestionsHTML: liveTurn.pendingSuggestionsHTML)` and `MessageRecord.encode(_:)` it into `attachmentsJSON`; reset the accumulators on `.assistantMessageSaved` (where `broadcast` already clears text/thinking). Per Chat's documented exception, the transcript merges DB rows with the streaming tail through the `@Observable` view-model path (not GRDBQuery), so the pill updates through this event channel — no new observation. On the **next** turn, `ContextAssembler`/history reconstruction attaches the stored `sources` to the rebuilt assistant `LLMMessage` as a `.searchResult([SourceCitation])` block (§4.3) so the Anthropic adapter can replay the encrypted echo.

---

## 5. Per-provider adapters

All three are `public struct … : LLMProvider` (mirroring `OpenAICompatibleLLMProvider`, which is a struct holding an injected `HTTPClient`), live in `Packages/Chat/Sources/Chat/LLM/`, throw the existing `LLMError`, and follow the same `stream(...)` skeleton: `buildRequest → http.stream → SSEParser → reducer → continuation.yield`, terminating with `.messageComplete` and surfacing failures as `.error` then `.messageComplete` (never throwing out of the stream). Each reducer is a `struct` driven by `consume(_:)` + `finish()` (same pattern/ownership as `OpenAIStreamReducer`). Wire types are `Encodable`/`Decodable` structs.

> **SSE framing — good news, no parser change needed.** `SSEParser` already parses **named `event:` lines**: it yields `SSEEvent(event: String?, data: String)` (per the WHATWG EventSource spec, joining multi-line `data:`). So the existing parser already gives Anthropic / Gemini-SSE / OpenAI-Responses reducers the `event:` name they need — each reducer keys on `sseEvent.event` (e.g. `"content_block_delta"`, `"response.output_text.delta"`) and decodes `sseEvent.data`. No `SSEParser` extension required; the `decode(event.data)` loop in `OpenAICompatibleLLMProvider.stream` is the template, but native providers branch on `event.event` first. (`isDone`/`[DONE]` only applies to OpenAI Chat Completions; Anthropic ends on `message_stop`, Responses on `response.completed`, Gemini on the last chunk.)

### 5.1 Anthropic — `AnthropicNativeLLMProvider`

- **Endpoint:** `POST https://api.anthropic.com/v1/messages`. New catalog constant `anthropicNativeBaseURL`.
- **Headers:** `x-api-key: <key>`, `anthropic-version: 2023-06-01`, `content-type: application/json`, `accept: text/event-stream`. Attach key only when `isCleartextSafeForCredentials(url)` (same guard the OpenAI provider uses).
- **Request body** (`AnthropicMessagesRequest`): `model`, **`max_tokens` (required**; cap = open question §11), `stream:true`, `system` (string), `messages` (Anthropic content-block shape), `temperature`, `tools`. Native search tool appended **only when search is enabled for the turn** (§7):
  `{"type":"web_search_20250305","name":"web_search","max_uses":5}`. Regular client tools serialize as Anthropic custom tools `{"name","description","input_schema"}`. Tool version pinned to a single constant `anthropicWebSearchToolType = "web_search_20250305"`.
- **Thinking:** thinking models add `thinking:{"type":"enabled","budget_tokens":N}`; thinking blocks → `.thinkingDelta`.
- **Stream → reducer (`AnthropicStreamReducer`):**
  | SSE event/block | Reducer output |
  |---|---|
  | `message_start` | `.messageStart(id, model)` |
  | `content_block_start` text + `content_block_delta` `text_delta` | `.contentBlockStart(i,.text)` / `.textDelta(i,_)` |
  | `content_block_start`/`delta` thinking | `.contentBlockStart(i,.thinking)` / `.thinkingDelta(i,_)` |
  | `content_block_start` `server_tool_use` (name `web_search`) + `input_json_delta` | accumulate query; on block stop → `.searchStarted(query:)` |
  | `content_block_start` `web_search_tool_result` | parse `results[]`; stash `{url,title,encrypted_content,page_age}` by index (deferred until cited) |
  | `content_block_delta` `citations_delta` (`web_search_result_location`) | `SourceCitation(url,title, snippet:cited_text, publishedDate:page_age?, providerEcho:.init(kind:"anthropic.web_search", encryptedContent:<stashed>, encryptedIndex:encrypted_index))` → `.citations([…])` |
  | `content_block_start` `tool_use` (custom) + `input_json_delta` | accumulate args → `.toolUse(index,id,name,input)` |
  | `message_delta` `stop_reason` / `message_stop` | close blocks; `.messageComplete(usage:)` |
  | `error` event | `.error(.providerError(...))` |
- **GOTCHA — encrypted round-trip (mandatory).** Persist `encrypted_content`/`encrypted_index` in `SourceCitation.providerEcho` → `MessageAttachments.sources` (§4.4). On the next turn the rebuilt history carries them back as a `.searchResult` `LLMContent` block (§4.3); `AnthropicNativeLLMProvider.translate(_:)` reconstructs a synthetic `web_search_tool_result` content block from each echo, positioned before the cited text block, so Anthropic accepts the history. Document the tool-version constant + source URL in the adapter doc comment.

### 5.2 Gemini — `GeminiNativeLLMProvider`

- **Endpoint:** `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:streamGenerateContent?alt=sse`. New catalog constant `geminiNativeBaseURL` (note: distinct from the existing `googleBaseURL` `/openai` shim).
- **Auth:** prefer header **`x-goog-api-key: <key>`** (keeps the key out of URLs/logs) over `?key=`.
- **Request body** (`GeminiGenerateContentRequest`): `contents` (`role` user/model + `parts`), `systemInstruction` (no system role), `generationConfig:{temperature}`, `tools`. Native search: `tools:[{"google_search":{}}]` added only when search enabled (§7).
- **GOTCHA — `google_search` + client `functionDeclarations`.** Some Gemini models reject combining grounding with function tools in one request. **Decision:** when `searchEnabled`, prefer `google_search` for that turn; client tools route through the gated re-issue path (§7) which doesn't mix them. Verify per-model at integration; capture in a fixture test. (Open question §11 if a model needs both simultaneously.)
- **Thinking:** Gemini 2.5 parts with `thought:true` → `.thinkingDelta`; normal text parts → `.textDelta`.
- **Stream → reducer (`GeminiStreamReducer`):** each `data:` is a partial `GenerateContentResponse`.
  | Field | Reducer output |
  |---|---|
  | `candidates[0].content.parts[].text` (no `thought`) | `.textDelta(i,_)` |
  | part `thought:true` | `.thinkingDelta(i,_)` |
  | part `functionCall` | `.toolUse(index,id,name,input)` |
  | `groundingMetadata.webSearchQueries` (first seen) | `.searchStarted(query: queries.joined(", "))` |
  | `groundingMetadata.groundingChunks[].web.{uri,title}` + matching `groundingSupports[].segment.text` | `[SourceCitation(url:uri, title:title, snippet:segment.text, providerEcho:nil)]` → `.citations(…)` |
  | `groundingMetadata.searchEntryPoint.renderedContent` | `.searchSuggestionsHTML(html)` |
  | `candidates[0].finishReason` / last chunk | close blocks; `.messageComplete(usage: from usageMetadata)` |
- **GOTCHA — mandatory display compliance.** `searchEntryPoint.renderedContent` must render **unmodified and stay visible** whenever the grounded response is shown.
  - **`GeminiSearchSuggestionsView`** (new SwiftUI view, `Packages/Chat/Sources/Chat/UI/`): the fragment is HTML + inline CSS (chips deep-linking to Google Search, light/dark variants). Render via a constrained `WKWebView` in `UIViewRepresentable`:
    - `loadHTMLString(renderedContent, baseURL: nil)`.
    - Intrinsic height: after `didFinish`, `evaluateJavaScript("document.body.scrollHeight")`, publish height (~40–56pt). Pin width to the bubble content width.
    - Tap handling: chips are anchors to `google.com/search?…`. Intercept `decidePolicyFor navigationAction`; open user taps externally via `OpenURLAction`/`SFSafariViewController`; block all non-user-initiated navigation.
    - Disable scroll, selection, zoom; transparent background. Do **not** alter the HTML for Dynamic Type / Reduce Motion — only size the container.
  - **Coexistence with the pill:** the "N sources" pill (our affordance, collapsible) reads `MessageAttachments.sources`. The Suggestions strip (Google's required affordance) is **always shown**, not collapsible, directly under a grounded Gemini response. For non-Gemini providers `searchSuggestionsHTML == nil` and the strip is absent. Both read from the same `MessageAttachments`.

### 5.3 OpenAI — `OpenAIResponsesLLMProvider`

- **Decision: Responses API, not Chat Completions.** `web_search` is first-class on `/v1/responses` with structured streaming + `url_citation` annotations carrying offsets; Chat Completions' `web_search_options` is coarser and lacks the streaming citation events. The non-search OpenAI path stays on `OpenAICompatibleLLMProvider`; the native-search OpenAI path uses this new adapter.
- **Endpoint:** `POST https://api.openai.com/v1/responses`. New catalog constant `openAIResponsesBaseURL`.
- **Auth:** `Authorization: Bearer <key>` (cleartext guard), `content-type: application/json`, `accept: text/event-stream`.
- **Request body** (`OpenAIResponsesRequest`): `model`, `input` (Responses input items; user/assistant/tool), `instructions` (system prompt), `stream:true`, `temperature`, `tools`. Native search `tools:[{"type":"web_search"}]` (constant; fallback alias `web_search_preview`) added only when enabled (§7). Client tools serialize as Responses `function` tools.
- **Thinking:** `response.reasoning_summary_text.delta` → `.thinkingDelta`.
- **Stream → reducer (`OpenAIResponsesStreamReducer`):**
  | SSE event | Reducer output |
  |---|---|
  | `response.created` / first `output_item.added` | `.messageStart(id, model)` |
  | `response.web_search_call.in_progress` / `.searching` | `.searchStarted(query:)` (query from the search-call item if present, else generic) |
  | `response.output_text.delta` | `.textDelta(i,_)` |
  | `response.reasoning_summary_text.delta` | `.thinkingDelta(i,_)` |
  | `response.output_item.added` function_call + arg deltas | `.toolUse(index,id,name,input)` |
  | `response.output_text.annotation.added` (`url_citation`) | `SourceCitation(url,title, snippet:nil)` → `.citations([…])` (start/end_index retained only if inline highlighting is added later) |
  | `response.completed` | close blocks; `.messageComplete(usage:)` |
  | `response.error` / `error` | `.error(.providerError(...))` |
  Terminate on `response.completed` (no `[DONE]`).

---

## 6. Provider kind / catalog / hydration / settings (PR 2)

### 6.1 `LLMProviderKind`
Append three cases to the enum in `LLMTypes.swift` (`String, Codable, CaseIterable`; append only — existing raw values preserved):
```swift
case anthropicNative
case geminiNative
case openAIResponses
```
The doc comment on `LLMProviderKind` already anticipates "a native Anthropic Messages API provider, or a native Gemini provider," so this is the intended extension point. The *kind* records which adapter implements the model; it is selected at add-time when `searchBackend == "native"`.

### 6.2 `LLMProviderCatalog`
The template type is `LLMProviderCatalogEntry` (id, displayName, `kind: LLMProviderKind`, `defaultBaseURL`, `models: [LLMCatalogModel]`); `LLMProviderCatalog.all` is the hardcoded list. Today Anthropic's entry uses `defaultBaseURL: https://api.anthropic.com/v1/openai/` with `kind: .openAICompatible` (the shim), Google likewise. Its doc comment already says: *"Adding a native-Messages-API Anthropic adapter later would change Anthropic's `kind` here and require a parallel provider registration in `SettingsViewModel.registerProvider`."* This spec is that work.
- Add a `nativeSearchAdapter: LLMProviderKind?` field + `nativeSearchBaseURL: URL?` to `LLMProviderCatalogEntry`: OpenAI→`.openAIResponses` + `https://api.openai.com/v1`, Anthropic→`.anthropicNative` + `https://api.anthropic.com/v1`, Google→`.geminiNative` + `https://generativelanguage.googleapis.com/v1beta`; others `nil`. Convenience `supportsNativeSearch: Bool { nativeSearchAdapter != nil }`. (Keep these distinct from the OpenAI-compat `defaultBaseURL` so a model can be added either way.)
- Existing entries keep their `.openAICompatible` kind for the non-search path; the per-configuration kind + base URL are resolved at add-time from `nativeSearchAdapter`/`nativeSearchBaseURL` when `searchBackend == "native"`.

### 6.3 `ModelConfigurationRecord` + migration
`ModelConfigurationRecord` (table **`modelConfiguration`**, camelCase) currently has `id, kind, name, baseURL, apiKeyRef, modelId, supportsThinking, maxContextTokens, isSelected, createdAt`. Migrations live in `ChatDatabase.makeMigrator` and run `v1_createTables → v2_messageAttachments → v3_memory → v4_modelConfigurationKind → …` (the `kind` column itself was added by `v4`, which did a full table-rebuild because SQLite can't add a NOT-NULL-with-default mid-table via the DSL). **There is no pre-existing `searchBackend` migration — add one** as the next sequential migration (a plain nullable add is fine via the DSL, unlike `v4`):
```swift
migrator.registerMigration("v5_searchBackend") { db in
    try db.alter(table: "modelConfiguration") { t in
        t.add(column: "searchBackend", .text)   // "native" / "standalone" / nil
    }
}
```
Add `searchBackend: String?` to the record (defaulted in the init) + map it through the `configuration` computed property. At add-time, `kind` resolves to the entry's `nativeSearchAdapter` **iff** `searchBackend == "native"` **and** the entry has one; else `.openAICompatible`, and `baseURL` resolves to `nativeSearchBaseURL` vs `defaultBaseURL` correspondingly. (Coordinate with Engine B, which the standalone plan says also adds `searchEnabled: Bool` + `searchBackend: String?` — land **one** migration adding both columns if the tracks merge, so there aren't two `vN_search*` migrations racing.)

`ModelConfiguration` (Core) gains `searchBackend: String?` (defaulted nil) so the value reaches `hydrateProviders`; thread it through the `configuration` projection.

### 6.4 `hydrateProviders` (`App/Shell/AppBootstrapSupport.swift`)
Today `hydrateProviders` does `switch record.kind` over `.openAICompatible` (resolve `apiKey` from `repository.loadAPIKey(ref:)`, build `OpenAICompatibleLLMProvider(configuration:apiKey:http:)`), `.appleFoundation` (build `AppleFoundationLLMProvider`), and `#if DEBUG .debug` (`DebugLLMProvider`); a shared `URLSessionHTTPClient()` is reused for all rows. Add three arms, each resolving the Keychain key the same way as the `.openAICompatible` arm:
```swift
case .anthropicNative:
    await registry.register(AnthropicNativeLLMProvider(configuration: record.configuration, apiKey: apiKey, http: http))
case .geminiNative:
    await registry.register(GeminiNativeLLMProvider(configuration: record.configuration, apiKey: apiKey, http: http))
case .openAIResponses:
    await registry.register(OpenAIResponsesLLMProvider(configuration: record.configuration, apiKey: apiKey, http: http))
```
Mirror the same three arms in `SettingsViewModel.registerProvider`'s switch (it builds providers from `record.configuration` + `apiKey` + `httpClient` identically). **Extract a shared `makeProvider(for record: ModelConfigurationRecord, apiKey: String?, http: HTTPClient) -> any LLMProvider?` (or `for configuration:`) free function in Chat** so the two switches can't drift — currently they already duplicate the `.openAICompatible`/`.appleFoundation`/`.debug` arms, and adding three more doubles the drift risk. Each native adapter gets an `init(configuration:apiKey:http:)` convenience like `OpenAICompatibleLLMProvider`, precondition-checking its kind and unwrapping the native `baseURL`.

### 6.5 Add-Model UI
On the Add-Model page: a **"Web search" toggle**; when ON, a **backend dropdown**. If the template `supportsNativeSearch`, a `Native (<Provider>)` option appears and is the **default**; `Standalone` also offered. Providers without a native adapter show only `Standalone`. Selecting `Native (…)` writes `searchBackend = "native"` and resolves `providerKind` from `nativeSearchAdapter`. The dropdown's knowledge of "which providers have a shipped native adapter" comes solely from `ProviderTemplate.nativeSearchAdapter` — adding a future native provider is a catalog edit, no UI change. (This is the native half of the standalone plan's PR5 dropdown; coordinate so one dropdown serves both engines.)

---

## 7. Native cost-gate ("Ask before each search", default ON)

### 7.1 Problem
Native search runs server-side autonomously inside one completion — there is no mid-turn hook to interrupt before the provider searches.

### 7.2 Proposed flow (from the plan) + critique
**Plan's approach:** gate ON → run the turn with a lightweight **client** `request_web_search(query, reason)` proposal tool (NOT the provider's server tool). The model calling it triggers an inline confirm; approve → **re-issue** the turn with the native server tool enabled; gate OFF → include the native server tool directly.

**Critique — right shape; refinements:**
- ✅ Reuses Super's tool-call + confirmation machinery. `ChatSession.runTurnLoop` already loops `streamOneTurn → executeToolCalls` until a turn yields no tool calls; the standalone plan's PR3 adds the pause via `ToolCallRecord.status = .awaitingConfirmation` + `ChatEvent.toolCallAwaitingConfirmation` + `confirmToolCall(id:)`/`skipToolCall(id:)`. The native proposal tool reuses that exact gate — it is a client tool that always parks at `.awaitingConfirmation`. **Dependency:** the cost-gate confirmation plumbing should land in (or just before) PR 4; if Engine-B's PR3 lands first, PR 4 reuses it wholesale rather than reinventing it. Minimal new turn-loop code either way.
- ✅ Provider-agnostic — one mechanism for all three.
- ⚠️ **Latency:** gate-ON is two round trips (propose → approve → re-issue). The propose trip is cheap (one tool call, no generation). Acceptable for a default-ON safety gate; document (open question §11 — possible compromise: gate only the *first* search per conversation).
- ⚠️ **Re-issue fidelity:** on re-issue (a) drop the proposal tool, (b) add the native server tool, (c) optionally pass the approved query as guidance. Don't *force* the exact query — providers plan multi-query; over-constraining hurts quality.
- ⚠️ **Double-billing:** the proposal turn must instruct the model to **only** call `request_web_search` and not answer, so we don't pay for a full generation we discard. Handled by the system-prompt contract (§8).
- **Rejected alternative:** a session-wide "search allowed" toggle — that's just the gate-OFF behavior the user can already choose; doesn't satisfy per-search consent.

### 7.3 Threading `searchEnabled` to the adapter (no protocol change)
The `stream(messages:model:tools:temperature:)` signature is frozen. **Encode intent in `tools`:** `ChatSession` includes a sentinel `LLMTool` named `__native_web_search__` when search should be active (gate OFF, or post-approval). Each native adapter recognizes that name, translates it into its server-tool descriptor, and strips it from the normal function-tool list; non-native adapters ignore the unknown tool. **No signature change, no protocol churn.** (Alternative — a `stream` overload/config — rejected; touches every conformer.)

### 7.4 Mechanics
1. **Gate ON:** turn tools = `clientTools + [requestWebSearchProposalTool]`; **omit** `__native_web_search__`.
2. Model answers normally (done) **or** calls `request_web_search(query, reason)` → loop returns awaiting-confirmation → inline confirm ("Search the web for '<query>'? <reason>").
3. **Approve** → resume re-issues the turn with `tools = clientTools + [__native_web_search__]` (proposal tool removed), approved query passed as guidance. **Deny** → proposal tool returns a tool result ("User declined web search; answer from your own knowledge and say so if uncertain"); loop continues without search.
4. **Gate OFF:** `__native_web_search__` present from turn 1; adapter attaches the server tool; one round trip.

All cost-gate logic lives in `ChatSession` + the tool-name convention; zero protocol changes.

---

## 8. System-prompt changes

`SystemPromptBuilder` / `ContextAssembler` append per-engine guidance, injected only for native-search models:
- **Economy:** "Search the web only when the answer depends on current, post-training, or fast-changing facts, or when the user explicitly asks. Prefer your own knowledge for stable facts."
- **Citation expectation:** "When you use web results, ground your claims in them." (Providers attach citations automatically; this nudges grounded phrasing.)
- **Gated proposal contract (gate ON only):** "Web search requires user approval. If a search would materially improve your answer, call `request_web_search(query, reason)` with a single best query and a one-sentence reason, and **do not answer yet** — wait for the result. Don't call it for facts you already know." (Prevents double-billing.)
- Gemini compliance needs no prompt text — the strip is UI.
- Keep these as small composable fragments appended after the base instruction, gated on `searchBackend`/`searchEnabled`. (Unify with Engine B's prompt fragment so both engines read consistently.)

---

## 9. Testing strategy

Per root + Chat `AGENTS.md`: **LLM tests mock `LLMProvider` / never hit a real endpoint**; SSE fixtures captured once and replayed offline (`Tests/ChatTests/Fixtures/`); snapshot tests ship in the same PR as the views, recorded against CI's pinned trio (Xcode 26.4.1 / iOS 26.4.1 build `23E254a` sim / iPhone 17).

1. **Captured SSE fixtures (offline).** Per provider, capture real streams once (out of band) and commit raw SSE: plain text, thinking, regular tool-call, **search-with-citations**, and (Gemini) a turn with `searchEntryPoint`. Never re-fetch in CI.
2. **Reducer unit tests.** Feed each fixture line-by-line; assert the exact `[LLMStreamEvent]` sequence including the new cases and `SourceCitation` fields (esp. Anthropic `providerEcho.encryptedContent`/`encryptedIndex`). Cover `event:`+`data:` framing and split-across-lines JSON deltas.
3. **`ChatSession` integration tests (strict mocked provider, `FakeLLMProvider`-style, `fatalError` on misuse).**
   - Citations land in `MessageAttachments.sources` on `.messageComplete`; pill count + dedupe correct.
   - Anthropic `providerEcho` persists and is replayed as a `.searchResult` `LLMContent` on the next turn's rebuilt history (assert the history block contents).
   - Gate ON: proposal tool call → awaiting-confirmation; approve → re-issue includes `__native_web_search__`, drops proposal tool; deny → no sentinel, decline tool-result injected. Drain spawned work via the existing test seam **before** asserting (no `Task.sleep`/yield polling).
   - Gate OFF: sentinel present turn 1; one round trip.
4. **Snapshot tests (required, same PR as views).**
   - Sources pill: collapsed/expanded, 0/1/N sources, light/dark/sepia × default Dynamic Type + XXL reflow.
   - `GeminiSearchSuggestionsView`: a live `WKWebView` doesn't snapshot deterministically (async load, separate render process). Snapshot the **container** (fixed-height placeholder) for layout; unit-test the height-measurement + link-interception logic separately; manual-verify the actual render (open question §11). Never rerecord to force-pass.
5. **`DebugLLMProvider` sim seam.** Add a scripted branch (trigger phrase, e.g. "search:") that emits `.searchStarted → .textDelta → .citations([fixtures]) → .messageComplete`, and for a "gemini" trigger also `.searchSuggestionsHTML(<sample renderedContent>)`. Exercises pill + strip + cost-gate flow on-device, no network/key (the manual-sim seam from Chat `AGENTS.md`).

Coverage thresholds unchanged (Core ≥80%, Chat ≥70%). The new `v2_search_backend` migration gets an in-memory `DatabaseQueue` migration test.

---

## 10. PR breakdown (ordered; each shippable + testable)

1. **PR 1 — Shared plumbing.** `SourceCitation` + `ProviderEcho` + `.searchResult` `LLMContent` (Core); three new `LLMStreamEvent` cases; update all exhaustive switches; `MessageAttachments.sources`/`searchSuggestionsHTML` + `isEmpty`; optional `SSEParser` frame helper; `StreamAccumulator` + `persistAssistantMessage` landing logic; `DebugLLMProvider` search script + ChatSession tests proving the sink. Independently shippable (debug citations render).
2. **PR 2 — Kind/catalog/hydration/settings + migration.** Three `LLMProviderKind` cases; `ProviderTemplate.nativeSearchAdapter` + base URLs; `v2_search_backend` migration + `searchBackend` on record/`ModelConfiguration`; `hydrateProviders`/`registerProvider` arms via shared `makeProvider`; Add-Model toggle + dropdown. Native arms point at a temporary stub throwing `.requestFailed` until PR 3a, or land PR 2 immediately before PR 3a. Migration + settings-VM tests.
3. **PR 3a — Anthropic native adapter** (wire types + `AnthropicStreamReducer` + provider, encrypted round-trip via `.searchResult` replay, fixtures, reducer + ChatSession replay tests). Wires the `.anthropicNative` arm.
4. **PR 3b — OpenAI Responses adapter** (Responses request/stream/annotations, fixtures, tests).
5. **PR 3c — Gemini native adapter** (grounding mapping, fixtures, tests) **+ `GeminiSearchSuggestionsView`** (WebView + compliance) + its snapshot/unit tests.
6. **PR 4 — Cost gate.** `request_web_search` proposal tool, `__native_web_search__` sentinel recognized by all three adapters, ChatSession gate ON/OFF logic, system-prompt fragments, gate tests. (Until PR 4, adapters attach the server tool whenever the sentinel is present.)
7. **PR 5 — Sources pill UI** (`SourceCitationsPill`, collapsible) + snapshot matrix, wired to `MessageAttachments.sources`, coexisting with the Gemini strip.

PR 1 is the hard dependency for all. 3a/3b/3c are mutually independent (parallelizable). PR 5 needs only PR 1 (can use debug citations). PR 4 needs ≥1 adapter.

---

## 11a. Carried-forward review items from PR1/PR2 (must address in adapter PRs)

> **Status update (web-search Search-pane, fast-follow to PR4).** Wires the
> user-facing writer the PR4 gate was missing. Shipped:
> - **Persistence** — `ChatSettings.askBeforeSearching` (default `true`) +
>   `ChatSettingsStore` `Keys.webSearchAskBeforeSearching`
>   (`"webSearch.askBeforeSearching"`) read in `load()` and a
>   `setAskBeforeSearching(_:)` writer. The bootstraps now seed
>   `ChatSessionStore(askBeforeSearching: initialSettings.askBeforeSearching)`
>   so a persisted OFF survives relaunch (was hardcoded ON before).
> - **Fan-out seam** — `WebSearchPolicyReceiver` protocol (mirrors
>   `AutoCompactPolicyReceiver`; `ChatSessionStore` conforms via its existing
>   `setAskBeforeSearching`). `SettingsViewModel` gains the required receiver +
>   `setAskBeforeSearching(_:)` (persist + fan out to live sessions). Wired in
>   `AppShell` to `dependencies.chatSessionStore`.
> - **UI** — `SettingsSearchPane` (the "Ask before each search" toggle + a
>   cost/BYOK footnote), a `.search` case in `SettingsSheet.Pane`, a "Search"
>   row in `SettingsRootPane` (magnifying-glass `SearchIcon`, value
>   "Ask first" / "Automatic"). Snapshots: pane on/off × light/dark/sepia + XXL;
>   root pane re-recorded for the new row.
> - **Deferred PR4 nits folded in** — `ToolCallBlock` badge → "Awaiting approval"
>   (sentence case, with rationale comment + snapshot re-record); XXL snapshots
>   for `SearchConfirmationRow`'s resolved searched/skipped summaries; a
>   doc-comment on the success-path `resolveProposal` cancel-window (same known
>   exposure as `executeToolCalls`).
>
> Remaining: **Phase 2 = standalone Tavily/Brave**, which expands this same
> Search pane with per-provider key entry + a max-results control.

> **Status update (web-search PR4, native cost gate).** PR4 wires the
> `__native_web_search__` sentinel (recognized by all three adapters since
> PR3a–c but never injected until now) and lands the **"Ask before each
> search" cost gate**, default ON. Shipped:
> - **`NativeWebSearch` proposal surface** — a `request_web_search(query,
>   reason)` client tool + the sentinel as a buildable `LLMTool` + a
>   `nativeBackendValue` constant + `usesNativeSearch(_:)`.
> - **Detection without a new `stream`/`send` parameter** — `searchBackend`
>   now rides `LLMModel` (Core); the native adapters stamp it from their
>   `ModelConfiguration`, so `runTurnLoop` reads `model.searchBackend` off
>   the model it already holds (§7.3's "encode intent in `tools`" is realized
>   as: read the model, then append the sentinel/proposal). Resolves §11 open
>   question on how the session learns a model is native-search.
> - **Generic confirmation machinery** — `ChatEvent
>   .toolCallAwaitingConfirmation`, `ChatSession.confirmToolCall(id:)` /
>   `skipToolCall(id:)` (suspending `runTurnLoop` on a continuation, with a
>   cancellation handler that resumes it on turn cancel), driven through the
>   existing `ToolCallStatus.awaitingConfirmation`. Threaded through
>   `ChatSessionDriver` + `LiveChatSessionDriver` + `LazyConversationDriver` +
>   the view model (`confirmSearch`/`skipSearch`). Built generic (any tool can
>   opt into the pause) so the standalone engine + destructive tools reuse it.
> - **Gate turn-loop logic** — gate ON: advertise the proposal (no sentinel);
>   on approve re-issue with the sentinel (proposal dropped); on skip, write a
>   decline tool result and stop offering search for the rest of the loop (a
>   `searchDeclined` flag prevents a re-propose cycle); gate OFF: sentinel from
>   turn 1. Both flags reset per `send(...)`, so the gate prompts again for
>   every new user message (matches §0 #2: prompt before EVERY search,
>   per-user-turn granularity).
> - **Inline confirm UI** — `SearchConfirmationRow` (approve/skip prompt +
>   post-decision compact summary) routed in `AssistantMessage` so the internal
>   `request_web_search` name/JSON never leaks into a generic tool card.
>   Snapshot-tested (awaiting × light/dark/sepia + XXL, searched, skipped). A
>   `.awaitingConfirmation` badge was added to the generic `ToolCallBlock` for a
>   future destructive tool that parks there.
> - **System prompt** — `ContextAssembler.formatWebSearchBlock(model:)`, a
>   stable native-search-only block (economy + cite). The "propose and don't
>   answer yet" mechanic lives in the proposal tool's own description so it's
>   correct in both gate states.
> - **`DebugLLMProvider`** honors the proposal/sentinel so the gate is
>   exercisable in the simulator (a "search" message with the proposal tool
>   present emits a `request_web_search` call; with the sentinel it streams the
>   grounded answer + citations).
>
> **Carried-forward from PR4 (for the fast-follow Search settings pane):** the
> `webSearch.askBeforeSearching` `SettingRecord` read/write + the Settings
> **Search pane** that flips it are **deferred** — there's no writer yet, so
> `ChatSession`/`ChatSessionStore` default the gate ON (with a
> `setAskBeforeSearching(_:)` fan-out already in place). The pane PR wires the
> persisted read at bootstrap + the toggle UI. **Unverified-until-live:** the
> real provider behavior on the re-issued (approved) turn — that each adapter,
> given the sentinel + the synthetic approval tool result in history, actually
> performs the server search and grounds the answer — is covered by mocked
> `ChatSession` tests now and flagged for live validation alongside PR5.
>
> **Status update (web-search PR3a, OpenAI-first).** The native adapters are
> being delivered one provider per PR, **OpenAI Responses first** (it's the
> lowest-risk — no encrypted round-trip, no mandatory WebView), then Anthropic
> (PR3b), then Gemini (PR3c). PR3a shipped `OpenAIResponsesLLMProvider` +
> reducer + wire types + offline SSE fixtures, the shared `makeLLMProvider`
> factory (collapsing the `hydrateProviders`/`registerProvider` switches so they
> can't drift), the `SourceCitationsPill` + transcript projection, and the
> `DebugLLMProvider` search seam. It flipped **only** `.openAIResponses
> .hasProviderAdapter → true`; `.anthropicNative`/`.geminiNative` stay `false`
> until PR3b/PR3c. The `.openAIResponses`-specific items below are marked
> **DONE (PR3a)**; the Anthropic/Gemini-specific ones remain open.
>
> **Status update (web-search PR3b, Anthropic).** PR3b shipped
> `AnthropicNativeLLMProvider` + `AnthropicStreamReducer` + `AnthropicWireTypes`
> + offline SSE fixtures, the new `LLMContent.searchResult([SourceCitation])`
> carrier (§4.3) with the `ContextAssembler` round-trip that reattaches stored
> Anthropic echoes (gated on `providerEcho != nil`), the `makeLLMProvider`
> Anthropic arm, and flipped `.anthropicNative.hasProviderAdapter → true`. Only
> `.geminiNative` stays `false` (PR3c). **Tool version decision:** ships the
> **stable `web_search_20250305`** (constant `AnthropicWebSearch.toolType`), NOT
> §0 #3's `web_search_20260209` — the newer version is model-gated (excludes
> Haiku) and requires the server-side **code-execution tool** appended alongside
> (an extra capability we don't want on the public App Store target, and whose
> exact dated type string the spec never supplied / we can't verify offline). It
> is a one-line bump when the search path is live-testable (PR4) and gating is
> enforced (PR5). **Unverified-until-live (no live API in unit tests; the search
> sentinel isn't wired until PR4):** the extended-thinking request shape
> (`thinking` + temperature-omission + budget) and the encrypted round-trip
> replay shape (the synthetic `web_search_tool_result` `tool_use_id`, and whether
> a matching `server_tool_use` block must also be replayed). Both are
> covered by serialization-shape unit tests now and flagged in the adapter docs
> for live validation in PR4. The Anthropic-specific items below are now
> **DONE (PR3b)**.
>
> **Status update (web-search PR3c, Gemini — final native adapter).** PR3c
> shipped `GeminiNativeLLMProvider` + `GeminiStreamReducer` + `GeminiWireTypes`
> + offline SSE fixtures, mapping `streamGenerateContent?alt=sse` grounding
> (`groundingMetadata` → `.searchStarted`/`.citations`, `searchEntryPoint
> .renderedContent` → `.searchSuggestionsHTML`), the `makeLLMProvider` Gemini
> arm, and flipped `.geminiNative.hasProviderAdapter → true`. **All native-search
> kinds now have adapters**, so every known kind is buildable. It also ships
> `GeminiSearchSuggestionsView` (a constrained `WKWebView` rendering the mandatory
> Google Search-Suggestions HTML unmodified + always-visible under a grounded
> answer; height-measured, link-intercepted) wired through
> `AssistantMessage`/`MessageList`. Because the known-but-unbuildable-kind
> scenario is no longer reachable with a real kind (it recurs only when a future
> native kind is added ahead of its adapter), `GRDBModelConfigurationRepository`
> gained an injectable `isKindBuildable` predicate (default
> `hasProviderAdapter`) so the `selected()`/seed/`setSelected` guards stay
> tested; `SettingsViewModel.updateModel` was refactored to build-the-replacement
> -first (removing the `hasProviderAdapter` proxy that could drift from
> `makeLLMProvider`). **Gemini suggestions-HTML turn attribution (decided):** the
> HTML rides the assistant `MessageRecord` whose stream emitted it — i.e. the
> turn `ChatSession` persists on `.messageComplete` (the grounded turn). A
> cross-*turn* tool-loop split (HTML on the search turn, prose on a later turn) is
> not reachable until tool-gated search lands (PR4); revisit then if a real
> stream shows the split. **Unverified-until-live (no live API in unit tests; the
> search sentinel isn't wired until PR4):** the extended-thinking request shape
> (`thinkingConfig.includeThoughts`) and the client-tool round-trip
> (`functionResponse` keyed by function name, since Gemini matches results to
> calls by name; the reducer mints the call id as the name). Both are covered by
> serialization-shape unit tests now and flagged in the adapter docs. The
> Gemini-specific items below are now **DONE (PR3c)**; the `WKWebView` is verified
> by logic unit tests (height clamp + navigation policy) + manual render rather
> than a golden snapshot, per §0 #8.

From PR1:

- **Gemini suggestions-HTML turn attribution — DONE (PR3c).** The HTML rides the
  assistant `MessageRecord` whose stream emitted it (the turn `ChatSession`
  persists on `.messageComplete`). The cross-*turn* split (HTML on the search
  turn, prose later) isn't reachable until tool-gated search (PR4); revisit then
  if a real stream shows it. See the PR3c status note above.
- **`SourceCitation.id` uniqueness (all adapter PRs).** When a provider supplies no
  id, derive `id` from the full URL string (not just host) so a SwiftUI `ForEach`
  keyed on `id` can't collide. The sources pill must key on this.

From PR2 (#138) — these were flagged as latent native-kind hazards and have been
**defensively fixed in PR2 itself**, gated on the new
`LLMProviderKind.hasProviderAdapter` flag (native kinds report `false` until their
adapters ship). When PR3a lands an adapter it flips the relevant arm of that flag
to `true` and the guards below automatically start allowing the native path — no
separate cleanup needed. Each fix has a regression test:

- **`updateModel` unregister-then-`break` drops the provider — FIXED.**
  `SettingsViewModel.updateModel` now guards `registry.unregister(id:)` on
  `updated.kind.hasProviderAdapter`, so it only unregisters when
  `registerProvider` will actually re-register. (`updateModelKeepsNativeKindProviderRegistered`.)
  **DONE (PR3a):** the native `break` in `registerProvider` is gone — both
  `registerProvider` and `hydrateProviders` now route through the shared
  `makeLLMProvider` factory, which builds a real `OpenAIResponsesLLMProvider` for
  `.openAIResponses`. With its flag flipped, the unregister/re-register cycle
  resumes automatically for that kind; `.anthropicNative`/`.geminiNative` still
  return `nil` from the factory (and log the hydration skip) until PR3b/PR3c.
- **`SettingsModelDetailPane` URL-match misclassifies `.openAIResponses` rows —
  FIXED.** Classification is extracted to the testable
  `SettingsModelDetailPane.resolveEditProvider(kind:modelId:baseURL:)`, which
  classifies native (non-`hasProviderAdapter`) kinds **by kind, before** the
  URL-match branch — so an `.openAIResponses` row no longer URL-matches the compat
  `"openai"` entry. (`resolveEditProviderNativeKindByKind` +
  `resolveEditProviderCompatStillMatchesByURL`.) PR3a maps native kinds to their own
  native provider entries here instead of the current Custom fallback.
  - **⚠️ PR3a regression hazard — kind-before-URL guard — DONE (PR3a).**
    `resolveEditProvider` previously short-circuited native kinds via the
    `!kind.hasProviderAdapter` guard. PR3a flipped `.openAIResponses
    .hasProviderAdapter → true`, which would have lifted that guard and let the
    URL-match branch re-match the compat `"openai"` entry (shared
    `https://api.openai.com/v1`). **Fixed:** the guard was replaced with an
    explicit `switch kind { case .anthropicNative, .geminiNative,
    .openAIResponses: return Custom … }` that classifies the native kinds
    *before* the URL match, **independent of `hasProviderAdapter`** — so the flip
    can't reopen the collision. The tripwire
    (`resolveEditProviderNeverMisfilesOpenAIResponsesToCompat`) stays green, and
    `resolveEditProviderNativeKindByKind` now additionally asserts
    `LLMProviderKind.openAIResponses.hasProviderAdapter` to pin the post-flip
    state. (Custom is still the resolution target until the Add-Model native edit
    UI ships in PR5, which will map native kinds to their own entries here.)
  - **`updateModel` honors the edited Base URL for native kinds (PR2 hardening).**
    Because native rows route through the Custom pane (editable URL field), the
    `nextBaseURL` switch now persists the caller's URL for native kinds rather than
    silently discarding it. (`updateModelHonorsEditedURLForNativeKind`.) When PR3a
    gives native kinds their own read-only catalog entry, revisit whether the field
    should be read-only instead.
- **`selected()` returned an unbuildable native-kind row → empty registry — FIXED.**
  `selected()` now filters through `buildableKindRequest` (kinds with
  `hasProviderAdapter`), so a native-only-selected DB returns `nil` and the
  first-registered fallback fires cleanly instead of `setActive` swallowing
  `unknownProvider`. The row stays visible/editable via `all()`/`fetch(id:)`.
  (`selectedExcludesUnbuildableNativeKind` + `selectedReturnsBuildableRowDespiteNativeSibling`.)
  PR2 also keeps the warning log at the hydration skip site.
- **Seed paths must match `selected()`'s buildable filter — FIXED.** Once `selected()`
  moved to `buildableKindRequest`, the seed paths had to follow or a native-kind row
  could wedge the app empty: `insertIfEmpty`'s empty-check and `insertDebugIfMissing`'s
  selected-check now both count through `buildableKindRequest`, so a DB carrying only a
  native row still seeds AFM (recoverable model) and a selected native row doesn't block
  the debug seed from claiming selection. The demote helper was generalized
  (`demoteUnknownKindSelections` → `demoteUnselectableSelections`, filtering
  `!buildableKindRawValues.contains(kind)`) so it also frees the partial-unique slot held
  by a *native* selected row before a selected seed inserts — otherwise the seed would
  UNIQUE-violate. (`insertIfEmptySeedsWhenOnlyUnbuildableNativeRowExists`,
  `insertIfEmptyDemotesSelectedNativeRowBeforeSeeding`,
  `insertDebugIfMissingTakesSelectionWhenOnlyNativeKindRowIsSelected`.)
- **`setSelected(id:)` could select an unbuildable native row → no active model — FIXED.**
  `selected()` filters native kinds, but `setSelected` didn't — selecting a native id
  would demote every other row and then yield `nil` from `selected()`. `setSelected`
  now guards on `record.kind.hasProviderAdapter` and throws
  `ModelConfigurationRepositoryError.unselectableKind` *before* the demote, so the prior
  selection survives. The in-tree `StubModelRepository` mirrors the guard.
  (`setSelectedRefusesUnbuildableNativeKind`.) No production caller exists yet (the
  model-picker selection path is future work), so this is defensive for when it lands.
  - **Downgrade residue (tracked, low impact).** Because the guard throws *before*
    the demote, a native-kind `isSelected = 1` row written by a newer binary stays
    selected-on-disk after a downgrade until something clears it. It's invisible
    (`selected()` filters it, the UI never shows it as active) and **self-resolving**:
    the next `insertIfEmpty` sees zero buildable rows, demotes the native row via
    `demoteUnselectableSelections`, and seeds AFM into the slot; if a buildable row
    already exists, the first-registered fallback covers hydration and the stray flag
    is harmless under the partial unique index. PR3a's adapter flip removes the case
    entirely (the row becomes buildable and selectable). No fix needed in PR2; noted
    for the downgrade story.
- **`searchBackend: String?` magic literal `"native"` — STILL DEFERRED (re-scoped
  past PR3a-OpenAI).** PR3a does *not* branch on `searchBackend`: hydration and
  registration dispatch purely on `record.kind` (the kind already encodes
  native-vs-compat, resolved at add-time), so the factory never reads the string.
  The value set also isn't closed yet — it holds `"native"` today and gains the
  standalone-provider ids (`"tavily"`/`"brave"`) in Phase 2. The right place to
  introduce a typed `SearchBackend` + GRDB codec is the PR that first *branches* on
  the value: the **PR5 Add-Model native option** (which writes it) or Phase 2's
  standalone wiring. Coining the enum now would still have to be widened + migrated
  once those land, so it stays an untyped `String?` for PR3a.

## 11. Open questions / risks (need human decision)

1. **Spec location** — top-level `superpowers/specs/` (briefed) vs `docs/superpowers/specs/` (where real specs actually live). Pick one.
2. **Cost-gate latency** — two round trips on gate-ON. Accept as the safety default, or compromise (gate only the first search per conversation, then auto-allow)?
3. **Gemini WebView in snapshots** — container-only snapshot + logic unit tests + manual render verification proposed. Accept, or capture a manually-recorded golden PNG of the rendered strip?
4. **Gemini `google_search` + client function tools** — mutually exclusive on some models; plan routes client tools through the gated re-issue. Accept, or restrict native-Gemini models to search-only turns?
5. **`.searchResult` `LLMContent` in Core** — adds an Anthropic-shaped concept (encrypted echo) to the otherwise provider-neutral `LLMContent`. Justified by traveling through the existing `messages` array. Accept, or use a Chat-local side channel that bypasses the protocol?
6. **Anthropic `max_tokens`** — Messages API requires it; the OpenAI-compat path never surfaced it. Fixed cap (e.g. 4096) or derive from `maxContextTokens`?
7. **`SourceCitation` single source of truth** — this spec and the Engine-B plan both define it. Land one type; confirm the merged field set (this spec adds `providerEcho`).
8. **BYOK posture for SuperOS native search** — SuperBible is serverless (device→provider direct). Do SuperOS native-search models also call direct, or must they proxy through the backend (keys never on client)? Changes base-URL/auth wiring.
9. **Migrate the default path to native adapters later?** — long-term, route all Anthropic/Gemini/OpenAI traffic through native adapters and retire the `/openai/` shims, unifying on one path. Out of scope here; flag so we don't keep two permanent code paths per provider.
10. **Anthropic tool version** — confirmed two versions exist: `web_search_20250305` (no dynamic filtering, broadly available) and a newer `web_search_20260209` (adds dynamic domain filtering, gated to Opus 4.6+/Sonnet 4.6+). Spec pins `web_search_20250305` as the safe default constant `anthropicWebSearchToolType`. Decide whether v1 ships `20250305` or `20260209` (latter needs the model gate check). Either way it's a one-constant change.

