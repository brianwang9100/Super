# ChatLiveLLM

End-to-end smoke script that drives the Chat orchestration layer
(`ChatSessionStore` → `ChatSession` → `OpenAICompatibleLLMProvider`)
against a live local OpenAI-compatible LLM server.

Not run by CI. Kept for on-demand integration testing.

## Usage

```sh
cd Scripts/ChatLiveLLM
swift run ChatLiveLLM
```

## Configuration

Override defaults via env vars:

| Variable            | Default                       | Notes                                                       |
|---------------------|-------------------------------|-------------------------------------------------------------|
| `OMLX_BASE_URL`     | `http://127.0.0.1:1111/v1`    | Base URL ending in `/v1`                                    |
| `OMLX_API_KEY`      | `omlx-local-dev`              | Bearer token (any value for local dev)                      |
| `OMLX_MODEL`        | `Qwen3.6-35B-A3B-bf16`        | Model id served by the endpoint                             |
| `OMLX_SKIP_TOOL`    | `0`                           | Set to `1` to skip the tool-use turn                        |
| `OMLX_SKIP_COMPACT` | `0`                           | Set to `1` to skip the `/compact` + post-compaction turns   |

Examples:

```sh
# point at a different port
OMLX_BASE_URL=http://127.0.0.1:8080/v1 swift run ChatLiveLLM

# skip the tool-use turn (faster sanity check)
OMLX_SKIP_TOOL=1 swift run ChatLiveLLM
```

## What it does

1. Spins up an in-memory `ChatDatabase` and the GRDB repositories.
2. Seeds one conversation row.
3. Registers `OpenAICompatibleLLMProvider` against the configured endpoint.
4. Registers a trivial in-process `echo` tool so the full
   tool-call → tool-result → follow-up-turn loop runs.
5. Sends up to four turns through `ChatSession.send(...)`:
   - **Turn 1**: plain text ("what is the capital of France?")
   - **Turn 2** (skippable via `OMLX_SKIP_TOOL=1`): tool use ("call `echo` with 'pong from echo' and summarize")
   - **Turn 3** (skippable via `OMLX_SKIP_COMPACT=1`): `/compact` — exercises the slash-command parser, the live `Compactor` against the real LLM, and persistence of a `CompactionCheckpointRecord`. With the default `keepMostRecent = 4`, this no-ops on a 1-turn run; the script tags that case so it isn't mistaken for a failure.
   - **Turn 4** (skippable via `OMLX_SKIP_COMPACT=1`): a follow-up question that exercises the post-compaction prompt assembly — the next prompt should carry the synthetic summary as a leading system message.
6. Streams `ChatEvent`s to stdout as they arrive (including `compactionStarted` / `compactionCompleted`).
7. Prints the live `CompactionCheckpointRecord` (id, `uptoMessageId`, before/after token counts, summary preview) when one was persisted.
8. Prints the final persisted message + tool-call rows; each message is tagged `(covered)` (represented by the live summary) or `(kept)` (passed through verbatim).
