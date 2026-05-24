# Super

[![Swift Tests](https://github.com/brianwang9100/Super/actions/workflows/swift-test.yml/badge.svg?branch=main)](https://github.com/brianwang9100/Super/actions/workflows/swift-test.yml)
[![iOS Build](https://github.com/brianwang9100/Super/actions/workflows/ios-build.yml/badge.svg?branch=main)](https://github.com/brianwang9100/Super/actions/workflows/ios-build.yml)
[![SwiftLint](https://github.com/brianwang9100/Super/actions/workflows/swiftlint.yml/badge.svg?branch=main)](https://github.com/brianwang9100/Super/actions/workflows/swiftlint.yml)
[![Secrets Scan](https://github.com/brianwang9100/Super/actions/workflows/secrets-scan.yml/badge.svg?branch=main)](https://github.com/brianwang9100/Super/actions/workflows/secrets-scan.yml)

A monorepo containing **two apps** built from one shared codebase:

- **SuperOS** — a chat-first, AI-native personal productivity app (Chat host + ToDo + Recipes + Finance + …). Founder's personal app, not heading to the App Store.
- **SuperBible** — a chat-first AI Bible app: read scripture, follow plans, and converse with an AI about what you're reading. Free, BYOK, open source, local-first. **Public App Store target.**

Both apps share `Core`, `Chat`, and `Bible` packages; each ships its own composition root and applet set. See [`docs/superpowers/specs/2026-05-23-superbible-fork-design.md`](docs/superpowers/specs/2026-05-23-superbible-fork-design.md) for the fork rationale.

> **Status:** Super MVP M0–M12 complete (2026-05-10) — Chat is shipped, Bible and Todo packages exist in the repo, the SuperOS app target is buildable. SuperBible target is **not yet wired up** — see [`TODO.md`](TODO.md) § SuperBible for the SB-M0 through SB-M5 plan.

See [`docs/PRODUCT_VISION.md`](docs/PRODUCT_VISION.md) for the long version.

## What works today

| Surface | Status |
|---|---|
| **Chat applet** | Streaming chat against any OpenAI-compatible endpoint (BYOK). Markdown + Splash-highlighted code blocks. Thinking traces. Tool calls (built-in `time.now`). Per-conversation model selection. Sidebar drawer. Settings sheet (theme, verbosity, models, prompt, compaction, tools). On-device voice dictation via `SFSpeechRecognizer`. Auto-titling + auto-compaction. |
| **iOS app shell** | Native SwiftUI. Light / Dark / Sepia themes. Dynamic Type up to XXL. Reduce Motion respected. |
| **Server** | Not yet built. Chat runs fully on-device against the user's chosen LLM endpoint. |
| **Sync** | Not yet built. Each install is local-only. |
| **Other applets** | Designed in [`docs/`](docs/), not implemented. |

MVP complete (2026-05-10). Open work: [`TODO.md`](TODO.md). Archived milestone build log: [`docs/archived/IMPLEMENTATION_STATUS.md`](docs/archived/IMPLEMENTATION_STATUS.md).

## Build & run

**Prereqs:** macOS 15+, Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/brianwang9100/Super.git
cd Super
xcodegen generate          # produces Super.xcodeproj from project.yml
open Super.xcodeproj
```

Two app schemes are generated:

- **`Super`** — the SuperOS app target (Chat + Bible + Todo).
- **`SuperBible`** — the SuperBible app target (Chat + Bible + Plans). *Planned. Wired up at milestone SB-M0 — see [`TODO.md`](TODO.md) § SuperBible.*

Pick a scheme + an iPhone simulator and ⌘R. On first launch the app seeds Apple Foundation Models as the default chat model (free, on-device, no key). To use a stronger model: Settings → Models to add a chat-completions endpoint (Ollama, vLLM, LM Studio, OpenAI, Anthropic, etc.) and an API key. Keys live in the iOS Keychain — they never leave the device.

To run from the command line instead:

```bash
# SuperOS (current default)
xcodebuild build \
  -project Super.xcodeproj \
  -scheme Super \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  CODE_SIGNING_ALLOWED=NO

# SuperBible (once SB-M0 lands)
xcodebuild build \
  -project Super.xcodeproj \
  -scheme SuperBible \
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
├── App/                       # SuperOS app target — composition root only
├── App-SuperBible/            # SuperBible app target — composition root only (planned, SB-M0)
├── Packages/
│   ├── Core/                  # Shared primitives: HTTP, SSE, JSON, LLM, Tools, Ambient (shared by both apps)
│   ├── Chat/                  # Chat applet — host surface (shared by both apps)
│   ├── Bible/                 # Bible applet (shared by both apps)
│   ├── Todo/                  # Todo applet (SuperOS only)
│   └── Plans/, Memorize/, …   # SuperBible-only applets (planned)
├── Scripts/
│   ├── ChatLiveLLM/           # Standalone smoke runner against a real local LLM
│   └── xcodegen-extras/       # Per-package test schemes (xcodegen can't model these from project.yml)
├── docs/                      # Design + architecture docs (one source of truth per area)
│   ├── PRODUCT_VISION.md
│   ├── DESIGN.md
│   ├── MOBILE_ARCHITECTURE.md
│   ├── OBSERVABILITY.md       # Apple-built-in posture (no third-party SDKs)
│   ├── Chat/                  # Chat-specific architecture + design notes
│   ├── SuperBible/            # SuperBible-specific overview + observability
│   └── superpowers/specs/     # Per-milestone implementation specs
├── project.yml                # XcodeGen project definition
├── AGENTS.md                  # Project-wide rules (CLAUDE.md is a symlink to this)
└── TODO.md                    # Full backlog (the MVP milestone log lives at docs/archived/IMPLEMENTATION_STATUS.md)
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
3. See [`TODO.md`](TODO.md) for what's open. The MVP milestone build log is archived at [`docs/archived/IMPLEMENTATION_STATUS.md`](docs/archived/IMPLEMENTATION_STATUS.md).

## License

[MIT](LICENSE) © 2026 Brian Wang.
