# Chat: Design

> UI/UX design for the Chat applet — the conversational interface that is Super's primary surface today and the eventual orchestration hub for the rest of the shell.

> **Status (2026-05-03):** The MVP described in §1 is built and running on iOS. M0–M10 are complete; M11 (voice input) is implementation-complete and parked pending a physical-device verification walkthrough; M12 (polish + coverage) is in flight. See [`IMPLEMENTATION_STATUS.md`](../../IMPLEMENTATION_STATUS.md).

---

## 1. Overview & Scope

Chat is a **streaming conversation UI** with a local-first history, concurrent chats, thinking blocks, tool-call blocks, and code blocks. The MVP connects to any OpenAI-compatible LLM endpoint (BYOK) and runs entirely against local storage; cross-applet orchestration (action cards, suggest-and-confirm flows, split-view coordination with other applets) is explicitly **out of scope for this iteration** and will layer on once the conversational surface is solid.

Chat is the only applet that cannot be removed. All other applets register tools with Chat; for now those tools render as inline `tool` blocks inside assistant messages rather than as rich applet-specific action cards.

For the shell (navigation, applet manager, split view) see [`../DESIGN.md`](../DESIGN.md). For the planned cross-applet interaction catalog see [`../CHAT_INTERACTIONS.md`](../CHAT_INTERACTIONS.md).

---

## 2. Design Language

Chat's look is warm, paper-like, and quiet — closer to a Reader / Notes aesthetic than a typical chat UI.

### 2.1 Themes

Three themes. All palettes are expressed in OKLCH so accent-hue shifts stay perceptually stable.

| Theme | Background | Ink | Accent | Feel |
|-------|-----------|-----|--------|------|
| **Light** (default) | Soft pastel green `oklch(0.965 0.018 150)` | Warm gray `oklch(0.32 0.015 200)` | Deeper pastel green `oklch(0.52 0.09 155)` | Subtle, daylight-friendly |
| **Dark** | Deep green `oklch(0.22 0.025 155)` | Near-white `oklch(0.94 0.01 150)` | Muted mint `oklch(0.75 0.1 150)` | Calm, low-glare |
| **Sepia** | Warm cream `oklch(0.95 0.035 80)` | Brown-gray `oklch(0.32 0.03 60)` | Terracotta `oklch(0.55 0.13 45)` | Reading-mode |

The full token set is in [§10 Design Tokens](#10-design-tokens).

### 2.2 Typography

| Role | Face | Notes |
|------|------|-------|
| Wordmark, greetings, h3 | **Instrument Serif** (italic for wordmark) | Display only — never body text |
| UI, body, messages | **Geist** | Primary typeface, 15pt body |
| Code, context meter, tool names, version strings | **JetBrains Mono** | Lowercase, subtle letter-spacing |

Body text is 15pt at 1.0× font scale, line-height 1.55 for messages and markdown prose. Font scale is user-tunable in Appearance settings (0.85×–1.15×).

### 2.3 Motion

Motion is sparse and short: a typing caret inside streaming text, a pulse for thinking dots, a spinner for in-flight tools, and a slide for the settings sheet. No slide/fade-in for individual messages — tokens just appear.

---

## 3. Main Chat Screen

```
┌─────────────────────────────────────────┐
│  ≡       Italy trip planning          │ ← blurred header: menu + centered title
├─────────────────────────────────────────┤
│                                         │
│  Thinking ● ● ●           ▸           │ ← collapsed thinking block
│                                         │
│  That's a lovely time to go. A few      │ ← assistant: plain text, no bubble
│  things matter here: **June heat**...   │
│                                         │
│                    ┌──────────────────┐ │
│                    │  Perfect. What   │ │ ← user bubble: soft green, right-aligned
│                    │  hotel in B…?    │ │
│                    └──────────────────┘ │
│                                         │
│  🔧 search_hotels   ✓ done         ▸ │ ← tool call (collapsed)
│  Look at **Grand Hotel Majestic**...    │
│  [copy] [regenerate]                    │ ← inline message actions
│                                         │
├─────────────────────────────────────────┤
│ ╭─────────────────────────────────────╮ │
│ │ Chat with Super                     │ │ ← rounded composer (26pt radius)
│ │                                     │ │
│ │ [Opus 4.7 ▾] [Verbose ▾]  ▃ 42.3K/200K  🎤 │ │ ← model · verbosity · ctx meter · mic/send
│ ╰─────────────────────────────────────╯ │
└─────────────────────────────────────────┘
```

### 3.1 Header

- Sticky, full-width, sits on a **translucent blurred backdrop** (`backdrop-filter: blur(16px) saturate(1.4)` over the chat background at 85% opacity).
- **Left:** 40×40 circular menu button (hamburger icon) — opens the sidebar.
- **Center:** the active chat's title, truncated to **240pt max-width** with ellipsis. Font is UI (Geist), 15.5pt, medium weight. Tooltip on hover shows the full title.
- **Right:** an invisible 40×40 spacer that keeps the title visually centered relative to the menu button.

For a brand-new/empty chat the title renders as "New chat".

### 3.2 Message Area

Messages render inline in a single vertical column, scrolled to the bottom on new content. There is **no chat-side metadata** (no avatars, no role labels, no per-message timestamps). Identity comes from the bubble shape and alignment alone.

Auto-scroll sticks to the bottom as tokens stream. If the user scrolls up, streaming keeps going but does not force-scroll.

### 3.3 Composer

```
╭─────────────────────────────────────────╮
│  Chat with Super                        │
│                                         │
│  [Opus 4.7 ▾]  [Verbose ▾]    ▃ 42.3K/200K  ▶ │
╰─────────────────────────────────────────╯
```

- **Container:** pill-shaped (26pt corner radius), `--bg-raised` fill, 1pt border in `--border-faint`. On focus the border darkens to `--border` and a 4pt accent-tinted glow ring appears.
- **Textarea:** multi-line, auto-grows up to 120pt, then scrolls internally. Placeholder: "Chat with Super". `Enter` sends; `Shift+Enter` inserts a newline.
- **Footer row** (below the textarea, inside the pill):
  - **Model pill** — dropdown showing the current model's short name (e.g. "Opus 4.7"). Tapping opens a menu of configured models with their context-max (e.g. "Opus 4.7   200K"). Selecting a model changes it **for the active chat only**.
  - **Verbosity pill** — dropdown with Simple / Thinking / Verbose (see [§4.3](#43-verbosity)). Each option has a one-line description in the menu.
  - **Context meter** (right-aligned, mono font): a 26×3pt accent-filled progress track followed by `{used}K / {max}K`. Measured in thousands of tokens for the active chat.
  - **Mic/Send button** (34pt circular, far right):
    - Empty text → **mic icon** on a muted background. Tap records a voice message (future; ships as a no-op placeholder in MVP).
    - Non-empty text → **arrow-up icon** on accent-filled background. Tap sends.
  - This single button replaces any separate "+" / attach / live-voice affordance. Those are intentionally not in MVP.

Pills are small (11.5pt), transparent background, 1pt faint border, pill-shaped. They blend into the composer chrome and expand into dropdowns that pop upward.

---

## 4. Messages

Chat messages are composed of an ordered list of **parts**. A single assistant message can interleave text, thinking, tool calls, and code blocks in any order, and each part can be independently streamed.

Part types: `text` · `thinking` · `tool` · `code`.

### 4.1 User Message

```
                    ┌────────────────────┐
                    │ Perfect. What      │
                    │ hotel in Bologna?  │
                    └────────────────────┘
```

- Right-aligned.
- Soft green bubble (`--bubble-user`), ink text (`--bubble-ink`).
- 18pt corner radius, **6pt on the bottom-right** (tail corner).
- Max width 82% of the scroll area.
- Font 15pt, line-height 1.45, `white-space: pre-wrap` (preserves newlines).
- No bubble shadow, no timestamp.

### 4.2 Assistant Message

The assistant message has **no bubble and no background**. Parts render directly in the reading column with clear vertical rhythm between them.

- **Text parts** render as markdown (see [§4.6](#46-markdown)).
- Once the message finishes streaming, a small row of inline action buttons appears below: **Copy** and **Regenerate** (14pt icons, transparent, faint ink).

### 4.3 Verbosity

Verbosity controls the **default expanded/collapsed state** of thinking and tool-call blocks on assistant messages. It does not hide or delete them — all blocks always render; only the open/closed state changes.

| Mode | Thinking block | Tool call block |
|------|----------------|-----------------|
| **Simple** | Collapsed | Collapsed |
| **Thinking** | Expanded | Collapsed |
| **Verbose** | Expanded | Expanded |

The user can override the default for an individual block by tapping its chevron; that per-block override persists for the lifetime of the chat view.

### 4.4 Thinking Block

```
┌─────────────────────────────────────────┐
│ 🧠 Thinking  ● ● ●              ▸     │  ← collapsed
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│ 🧠 Thinking                     ▾      │
│ ─────────────────────────────────────── │
│ The user has specific constraints:      │
│ pregnancy (6mo), heat sensitivity...    │  ← italic, softer ink
└─────────────────────────────────────────┘
```

- Container: 12pt radius, `--bg-sunken` fill, 1pt `--border-faint` border.
- Header row (always visible): brain icon · label "Thinking" · (if streaming) three pulsing dots · chevron.
- Body (expanded only): italic, `--ink-soft`, 13pt, 1.55 line-height. Separated from the header by a 1pt hairline.
- While streaming, a typing caret trails the last character inside the expanded body.

### 4.5 Tool Call Block

```
┌─────────────────────────────────────────┐
│ 🔧 search_hotels   ◌ running    ▸     │  ← collapsed, in-flight
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│ 🔧 search_hotels   ✓ done       ▾     │
│ ─────────────────────────────────────── │
│ INPUT                                   │
│ ┌───────────────────────────────────┐   │
│ │ {"city":"Bologna","dates":...}    │   │  ← monospace, bg-raised
│ └───────────────────────────────────┘   │
│ RESULT                                  │
│ ┌───────────────────────────────────┐   │
│ │ 7 results. Top match: Grand...    │   │
│ └───────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

- Same container treatment as Thinking blocks (12pt radius, sunken bg, faint border).
- Header: tool icon · **tool name in monospace** · status chip · chevron.
- Status chip:
  - **running** — a small ring spinner + "running" label in faint ink.
  - **done** — accent-colored check icon + "done" in accent ink.
  - **error** (future) — red cross + "failed" in a warning color.
- Body (expanded only): an `INPUT` caption above a monospaced code-style panel containing the raw JSON args, then an optional `RESULT` caption + panel with the stringified tool output. Captions use uppercase 11pt `--ink-faint` with 0.5pt letter-spacing.

### 4.6 Markdown

Assistant text parts support a minimal markdown subset designed for chat, rendered incrementally as tokens stream:

- Paragraphs (blank-line separated), 12pt bottom margin
- Unordered and ordered lists (`- ` / `* ` / `1. `)
- `**bold**`
- `` `inline code` `` — 0.88em, JetBrains Mono, tinted background (`--code-inline-bg`)
- Fenced code blocks → a full **Code Block** component (see [§4.7](#47-code-block))
- `### Heading` → Instrument Serif, 24pt, 400 weight (used sparingly by the assistant)
- `<br/>` on single newlines within a paragraph

Links, tables, images, blockquotes, and nested lists are out of scope for MVP.

### 4.7 Code Block

```
┌─────────────────────────────────────────┐
│ typescript                    📋 copy   │  ← header bar
├─────────────────────────────────────────┤
│ const stream = await client.chat.       │
│   completions.create({                  │
│     model: 'opus-4.7',                  │
│     stream: true,                       │  ← syntax-highlighted, scrollable
│   });                                   │
└─────────────────────────────────────────┘
```

- Dark fill (`--code-bg`) in **all** themes — code blocks stay high-contrast regardless of theme.
- 12pt radius, overflow hidden.
- Header: lowercase language tag (mono, 11pt) on the left, a **copy** button on the right that flips to a check + "copied" for ~1.2s on click.
- Body: `<pre>`, JetBrains Mono 12.5pt, 1.55 line-height, horizontal scroll (hidden scrollbar) when content overflows.
- Lightweight syntax highlighter tokens: keywords, strings, numbers, comments, identifiers, punctuation. The palette is tuned to read well on the dark panel and is theme-independent.
- While streaming, a typing caret appears after the last token.

---

## 5. Streaming & Concurrency

### 5.1 Streaming

- Tokens append into the currently-streaming part of the current message.
- A **typing caret** (a blinking accent-colored bar) trails the last character of any `streaming` part — text, thinking, or code.
- Markdown is parsed incrementally. Partial bold/italic markers don't render formatting until closed; partial fenced code blocks do render the code panel so syntax highlighting can start immediately.
- Tool-call blocks render in the `running` state the moment they appear; once the tool call resolves, the chip flips to `done` with the result.

### 5.2 Concurrent Chats

Multiple chats can stream at once. The chat list in the sidebar is the source of truth for which chats are running. Switching away from a streaming chat does **not** cancel it — the backend keeps streaming; the UI picks up where it left off when the chat is reopened.

In the sidebar, a running chat shows a **small ring spinner to the left of its title**:

```
◌ Salomon stability hiking shoes
◌ Quick stir-fried snow pea leaves
  MacBook Pro charitable donation
```

The spinner is placed on the left (not the right) so users can scan the list edge for activity. It replaces any bullet or icon slot; idle chats render with just the title.

### 5.3 Error Banner

When a streaming chat terminates with a transport or provider error, an inline **error banner** replaces the streaming indicator at the bottom of the message list:

```
┌─────────────────────────────────────────┐
│  Connection lost. Response was        ↻ Retry │
│  interrupted.                                   │
└─────────────────────────────────────────┘
```

- Warm red tint (non-destructive looking), 12pt radius, 13pt text.
- Right-aligned Retry button (red fill, white text, 8pt radius) — resumes from the last assistant message.
- The partial response above the banner is preserved in history as-is; retry produces a new assistant message rather than mutating the failed one.

---

## 6. Sidebar

Revealed by tapping the menu button in the header. The sidebar is a **300pt fixed-width overlay** with a semi-transparent scrim (black @ 30%) behind it. Tapping the scrim or the menu button again closes it.

```
╔═════════════════════════════╗
║                             ║
║  Super            ← italic serif, 36pt
║  v0.3.1 · personal          ║
║                             ║
║  ┌───────────────────────┐  ║
║  │ ✨  New Chat          │  ║ ← green CTA pill (accent fill, light text)
║  └───────────────────────┘  ║
║  ☑️  Todo                   ║
║  🍳  Recipes                ║
║  ✝   Bible                  ║
║  💰  Finance                ║
║                             ║
║  CHATS                      ║ ← 11pt uppercase, letter-spaced
║  ◌ Salomon stability…       ║
║  ◌ Quick stir-fried snow…   ║
║    Italy trip planning      ║ ← active: accent-soft fill, accent text
║    Building a local chat…   ║
║    Substituting crushed…    ║
║    Why the sky is blue      ║
║    ...                      ║
║                             ║
║  ┌─────────────────┐  ┌──┐  ║
║  │ BW  Brian Wang  │  │⚙│  ║ ← profile pill + floating settings
║  └─────────────────┘  └──┘  ║
╚═════════════════════════════╝
```

### 6.1 Header

- **Wordmark** — "Super" in Instrument Serif italic, 36pt, −0.015 letter-spacing, color `--ink`.
- **Subtitle** — `v{version} · {tagline}` in JetBrains Mono 10pt, `--ink-faint`.

### 6.2 Applets

A short list of applet entry points. The first entry is always **New Chat**, styled as a primary call-to-action: accent-filled background, light ink text, 14pt corner radius, subtle accent-tinted shadow, 16pt medium-weight label.

Subsequent applets render as plain rows (transparent, 12pt radius, hover → `--bg-sunken`). MVP surfaces: `Todo`, `Recipes`, `Bible`, `Finance`. These are placeholders for future applets — tapping them is a no-op for now but the affordance is in place so users can see where the product is going.

### 6.3 Chats Section

Header: **"CHATS"** — 11pt uppercase, 1pt letter-spacing, `--ink-faint`. (Note: not "Recents".)

Each row:
- **Running indicator** (if applicable) — small ring spinner on the left, using `--accent` on `--border`. Idle rows have no leading glyph.
- **Title** — 14.5pt, truncated with ellipsis.
- **Active chat** — filled with `--accent-soft`, title recolored to `--accent`, weight 500.
- **Inactive hover** — transparent → `--bg-sunken`.

Chats are sorted by `updatedAt` descending. Tapping a chat selects it and closes the sidebar.

### 6.4 Profile & Settings

Pinned to the bottom of the sidebar (24pt from the edge):

- **Profile pill** (left, flex-filled): 30pt circular monogram avatar (user initials on `--accent-soft`) + user display name in 13.5pt ink. The pill itself has a raised background, faint border, and a soft shadow.
- **Settings button** (right, 44×44pt circular): accent-filled, icon-only (gear), small elevation shadow. Tapping opens the Settings modal and closes the sidebar.

---

## 7. Settings

The Settings modal is a **bottom sheet**: slides up from the bottom, anchored 40pt from the top, with a 22pt top-corner radius. Backdrop scrim at 25% black. Slide curve: `cubic-bezier(0.32, 0.72, 0, 1)` over 300ms.

### 7.1 Header

- **Root pane:** a close button (X) on the left, centered title "Settings", a hidden spacer on the right that keeps the title centered.
- **Sub-pane:** a back-chevron on the left (returns to root), centered sub-pane title, same hidden spacer on the right.

### 7.2 Root Pane

```
┌─────────────────────────────────┐
│ ×            Settings           │
├─────────────────────────────────┤
│  brianwang9100@gmail.com       │ ← account chip
├─────────────────────────────────┤
│ ⬢ Models              4 configured › │
│ 🌙 Theme              Light  › │
├─────────────────────────────────┤
│ 📝 System Prompt             › │
│ 🗣 Default Verbosity Verbose › │
│ 🪟 Appearance                 › │
├─────────────────────────────────┤
│ 🗃 Data              12 chats › │
│ ⓘ About              v0.3.1  › │
└─────────────────────────────────┘
```

Rows are 14pt vertical padding, 18pt horizontal, grouped into rounded-14pt cards with a faint border and `--bg-raised` fill. Each row: leading icon, label, trailing value/chevron. Hairline dividers (1pt `--border-faint`) between rows inside a group; no divider before/after the first/last row.

### 7.3 Models Pane

Lists each configured LLM model as a card:

- **Monogram tile** (36×36, accent-soft fill, accent ink, mono) — e.g. "O4" for Opus 4.7.
- **Name** — 15pt medium.
- **Metadata** — mono 12pt, faint ink: `{ctxMax}K ctx · {endpoint}`.
- **Enabled toggle** — a custom iOS-style 44×26 switch (accent on, border off) with a white thumb.

Below the list, a dashed-border "Add model endpoint" button (1pt dashed `--border`, `--ink-soft`, plus icon) opens a model-editor (API-key + endpoint + model ID — future).

MVP ships with four preconfigured models that users can enable/disable: **Opus 4.7** (200K), **GPT 5.5** (256K), **Qwen3.6** (128K), **Gemma 4** (64K).

### 7.4 Theme Pane

A 3-column grid of theme previews (Light, Dark, Sepia). Each preview is a rounded card showing a miniature of the theme's bg, accent bar, ink bars, and a faux input pill; the selected theme gets a 2pt accent border plus a 3pt accent-tinted outline and a "✓" marker in its label row.

Accent hue is globally tunable via the Tweaks dev panel (0–360°) during design iteration; users don't see a hue slider in MVP.

### 7.5 System Prompt Pane

A single large textarea (10 rows, resizable-vertical), `--bg-raised` background, 14pt border-radius, faint border, 14pt body font. Under the field: `"Applied to new chats. {N} chars."` in faint ink. Editing is immediate — no "Save" button.

Default: `"You are Super, a thoughtful personal assistant. Answer directly and well."`

### 7.6 Default Verbosity Pane

Three rows (Simple / Thinking / Verbose) in a grouped card, each showing:

- Title (15pt)
- Description (12.5pt faint ink) — the same descriptions as in the composer's Verbosity pill

Selected option shows a trailing accent check. Applies only to **newly created chats**; the active chat keeps its own verbosity.

### 7.7 Appearance Pane

- **Font size** — a range slider 0.85×–1.15×, step 0.05, accent-colored track. Labels: Small / {percentage} / Large. The slider scales all body typography live.
- **Density** — three options (Compact, Comfortable, Spacious) in a grouped card, with a trailing accent check on the selected row. Density affects message spacing, composer padding, and sidebar row height.

### 7.8 Data Pane

- **Export all chats** — writes a `.json` file with the full chat history.
- **Import chats** — reads a `.json` file and merges into the local DB.
- **Clear chat history** — a destructive action; trailing label renders in red (`oklch(0.55 0.14 30)`). Tapping prompts a confirmation before wiping.

### 7.9 About Pane

Centered Instrument Serif italic "Super" at 56pt, mono version/build line below, and a short tagline: *"A personal chat app. Your chats stay on device."*

---

## 8. Empty States

### 8.1 New Chat

```
┌─────────────────────────────────────────┐
│  ≡                New chat              │
├─────────────────────────────────────────┤
│                                         │
│                                         │
│                 ✦                       │ ← accent spark icon
│                                         │
│         How can I help you              │ ← Instrument Serif, 26pt
│          this afternoon?                │
│                                         │
│                                         │
├─────────────────────────────────────────┤
│  [composer]                             │
└─────────────────────────────────────────┘
```

- A single greeting, vertically centered with a small accent "spark" icon above (36pt, 0.8 opacity).
- Greeting is time-of-day aware: "…tonight?" / "…this morning?" / "…this afternoon?" / "…this evening?" / "…tonight?" (after 21:00).
- No suggestion chips, no sample prompts — the blank composer is the call to action.

### 8.2 No Configured Models

If every model in Settings → Models is disabled (or none are configured), the composer's send button is disabled and the greeting is replaced with a short inline hint: *"Enable a model in Settings to start chatting."* (MVP: static text; no fancy onboarding flow.)

---

## 9. Accessibility

- **VoiceOver labels** on every icon-only control (menu, send, mic, settings gear, copy, regenerate, thinking/tool chevrons, theme swatches).
- **Dynamic Type** — all body fonts respect the Appearance font-scale multiplier. Minimum tap target is 44×44pt (mic/send is 34pt visual + transparent hit area padding to 44pt).
- **Reduce Motion** — when enabled:
  - The settings sheet fades in/out instead of sliding.
  - Streaming text appears without the typing caret.
  - Thinking-dots and spinner animations freeze on a static state icon.
- **Color-contrast** — at least AA for all ink-on-bg pairs across the three themes. Status is always conveyed by icon + label, never color alone (running spinner + "running", done check + "done").
- **Keyboard (Mac)** — `Cmd+Return` sends, `Cmd+N` starts a new chat, `Cmd+,` opens Settings, `Esc` closes sidebar/settings/modal dialogs.

---

## 10. Design Tokens

CSS custom properties set on the root element per theme. All values are OKLCH to keep derived shades (mixes, soft variants) perceptually uniform across themes.

| Token | Purpose |
|-------|---------|
| `--bg` | Page background |
| `--bg-raised` | Cards, composer, profile pill, settings rows |
| `--bg-sunken` | Thinking/tool block bodies, hover row, code-inline bg mix |
| `--sidebar` | Sidebar fill (slightly different from `--bg`) |
| `--ink` | Primary text |
| `--ink-soft` | Secondary text (captions, tool-block body) |
| `--ink-faint` | Tertiary (timestamps, meters, placeholders) |
| `--ink-mute` | Disabled state |
| `--accent` | Interactive accent (send button, active chat, CTA) |
| `--accent-ink` | Text on accent fills |
| `--accent-soft` | Tinted backgrounds (active chat row, monogram tiles) |
| `--border` | 1pt card/panel borders |
| `--border-faint` | Hairlines, composer resting border, row dividers |
| `--code-bg` / `--code-fg` | Fenced code block panel |
| `--code-inline-bg` / `--code-inline-fg` | Inline `` `code` `` pill |
| `--bubble-user` / `--bubble-ink` | User message bubble |
| `--shadow` | Composite drop shadow for raised surfaces |

Common geometry:

| Token | Value |
|-------|-------|
| Composer radius | 26pt |
| Card / panel radius | 12–14pt |
| Settings sheet radius | 22pt (top corners only) |
| Sidebar width | 300pt |
| Chat title max-width | 240pt |
| User bubble radius | 18pt (6pt on bottom-right tail) |
| User bubble max-width | 82% of message column |
| Message body font | Geist 15pt / 1.55 |
| Monospace fallback | `JetBrains Mono, ui-monospace, monospace` |

---

## 11. Out of Scope (for MVP)

Explicitly deferred so the MVP stays small. When these land they'll extend — not replace — what's in this document.

- Inline action cards, suggestion cards with approve/reject/edit, undo affordances, biometric confirmation on destructive tool calls
- Cross-applet split-view coordination (Chat drives changes animating in a second panel)
- Deep links from tool results into other applets
- Voice input/output — the composer's mic button ships as a visual affordance only in MVP
- Attachments (images, files)
- Conversation search, renaming from the sidebar, swipe-to-delete
- A real activity-summary context construction for the system prompt
