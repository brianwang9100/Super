# Chat

Read [ARCHITECTURE.md](../../docs/Chat/ARCHITECTURE.md) for orchestration and [UI_STRUCTURE.md](../../docs/Chat/UI_STRUCTURE.md) for UI work.

- Persist the final streaming `MessageRecord` only on `.messageComplete`; don't persist intermediate text buffers.
- The shared markdown renderer lives in Core. Keep `ChatAppearance.markdownMetrics` equal to Core's default at 1.0× (`ChatAppearanceTests`).
- Tests mock `LLMProvider`; use the strict `FakeLLMProvider` contract and never hit a real provider endpoint.
- For view-model assertions, drain `_waitForPendingStreamTask()` **before** `_waitForPendingTitleTask()`. Voice tests consume `VoiceInputController._observeProcessedEvents()`.

## Simulator streaming UI

Use `DebugLLMProvider`, not a real model or API key. Both app bootstraps seed DEBUG model choices; select the canned streaming model in the picker if a real model was already active. Extend `responseBank` in `Sources/Chat/LLM/DebugLLMProvider.swift` when a new response shape is needed. The debug providers must remain excluded from Release builds.
