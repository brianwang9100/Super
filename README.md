# Super

[![Swift Tests](https://github.com/brianwang9100/Super/actions/workflows/swift-test.yml/badge.svg?branch=main)](https://github.com/brianwang9100/Super/actions/workflows/swift-test.yml)
[![iOS Build](https://github.com/brianwang9100/Super/actions/workflows/ios-build.yml/badge.svg?branch=main)](https://github.com/brianwang9100/Super/actions/workflows/ios-build.yml)
[![SwiftLint](https://github.com/brianwang9100/Super/actions/workflows/swiftlint.yml/badge.svg?branch=main)](https://github.com/brianwang9100/Super/actions/workflows/swiftlint.yml)

A chat-first, AI-native productivity app for iOS and macOS. Chat is the host surface; mini-apps (ToDo, Recipes, Bible, Finance, …) plug into the conversation in both directions — the AI can drive them via tool calls, and any record can be piped back into chat.

> **Status:** early development. Chat applet only; mini-apps are designed but not yet built.

See [`docs/PRODUCT_VISION.md`](docs/PRODUCT_VISION.md) for the long version.

## What works today

| Surface | Status |
|---|---|
| **Chat applet** | Streaming chat against any OpenAI-compatible endpoint (BYOK). Markdown + Splash-highlighted code blocks. Thinking traces. Tool calls (built-in `time.now`). Per-conversation model selection. Sidebar drawer. Settings sheet (theme, verbosity, models, prompt, compaction, tools). On-device voice dictation via `SFSpeechRecognizer`. Auto-titling + auto-compaction. |
| **iOS app shell** | Native SwiftUI. Light / Dark / Sepia themes. Dynamic Type up to XXL. Reduce Motion respected. |
| **Server** | Not yet built. Chat runs fully on-device against the user's chosen LLM endpoint. |
| **Sync** | Not yet built. Each install is local-only. |
| **Other applets** | Designed in [`docs/`](docs/), not implemented. |

Live milestone status: [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md). Full backlog: [`TODO.md`](TODO.md).

## Build & run

**Prereqs:** macOS 15+, Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/brianwang9100/Super.git
cd Super
xcodegen generate          # produces Super.xcodeproj from project.yml
open Super.xcodeproj
```

Pick an iPhone simulator and ⌘R. On first launch the app drops you into a fresh chat. Open Settings → Models to add a chat-completions endpoint (Ollama, vLLM, LM Studio, OpenAI, etc.) and an API key. The keys live in the iOS Keychain — they never leave the device.

To run from the command line instead:

```bash
xcodebuild build \
  -project Super.xcodeproj \
  -scheme Super \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  CODE_SIGNING_ALLOWED=NO
```

## Tests

Each Swift package owns its own test suite:

```bash
swift test --parallel                          # from Packages/Core/ or Packages/Chat/
xcodebuild test \                              # snapshot tests need iOS sim
  -project Super.xcodeproj -scheme Chat \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

CI runs both on every push. Coverage thresholds (per [`AGENTS.md`](AGENTS.md)): Core ≥ 80%, applets ≥ 70%.

## Repository layout

```
Super/
├── App/                       # iOS app target — composition root only
├── Packages/
│   ├── Core/                  # Shared primitives: HTTP, SSE, JSON, LLM, Tools, Ambient
│   └── Chat/                  # Chat applet (models, repos, orchestration, UI, voice, settings)
├── Scripts/
│   └── ChatLiveLLM/           # Standalone smoke runner against a real local LLM
├── docs/                      # Design + architecture docs (one source of truth per area)
│   ├── PRODUCT_VISION.md
│   ├── DESIGN.md
│   ├── MOBILE_ARCHITECTURE.md
│   ├── Chat/                  # Chat-specific architecture + design notes
│   └── superpowers/specs/     # Per-milestone implementation specs
├── project.yml                # XcodeGen project definition
├── AGENTS.md                  # Project-wide rules (CLAUDE.md is a symlink to this)
├── IMPLEMENTATION_STATUS.md   # What's built vs. what's not
└── TODO.md                    # Full backlog
```

## Design philosophy

- **Chat is the host**, not a tab. Mini-apps render *behind* the chat in three coordinated overlay states.
- **Bi-directional AI.** Chat drives mini-apps via tool calls; mini-apps pipe records back into chat via long-press.
- **Offline-first.** GRDB/SQLite is the local source of truth. On-device LLMs (MLX, Apple Foundation Models) are first-class; cloud endpoints are optional.
- **BYOK.** Super is open source; no API keys ship with the binary. Users provide their own.
- **AI-built.** Every commit so far is the work of an AI agent under human review. The CI pipeline is the immune system that keeps that safe.

See [`docs/PRODUCT_VISION.md`](docs/PRODUCT_VISION.md) §2 for the full set of principles.

## Contributing

This is an experimental project; the codebase moves quickly. If you want to dig in:

1. Read [`docs/PRODUCT_VISION.md`](docs/PRODUCT_VISION.md), [`docs/DESIGN.md`](docs/DESIGN.md), and [`docs/MOBILE_ARCHITECTURE.md`](docs/MOBILE_ARCHITECTURE.md).
2. Skim [`AGENTS.md`](AGENTS.md) — it codifies the conventions every PR follows (Swift 6 strict concurrency, GRDB naming, structs-vs-classes, testing rules).
3. See [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) for what's in flight and [`TODO.md`](TODO.md) for what's open.

## License

[MIT](LICENSE) © 2026 Brian Wang.
