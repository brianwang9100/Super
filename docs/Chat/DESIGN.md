# Chat: Design

> UI/UX design for Chat — the AI chat interface and cross-applet orchestrator at the heart of Super.

---

## 1. Overview

Chat is the always-present AI chatbot that acts as Super's "universal remote." Users speak to it in natural language and it orchestrates actions across all other applets via tool calls. It is powered by Claude (or Open Claw) with streaming responses, multi-turn conversation history, and voice I/O.

Chat is the only applet that cannot be removed. It is the orchestration hub — every other applet registers its tools with Chat, and Chat invokes them on the user's behalf.

**Accent color:** Purple
**Icon:** `brain` (SF Symbol)

For the full catalog of cross-applet interactions (66 user stories, 6 response types), see [CHAT_INTERACTIONS.md](../CHAT_INTERACTIONS.md). For shell-level design (navigation, applet manager, split view), see the parent [DESIGN.md](../DESIGN.md).

---

## 2. Chat Interface Layout

### 2.1 iPhone — Full-Screen Chat

```
┌─────────────────────────────┐
│  Chat           ≡  ✎   │  ← title bar: conversation list (≡), new chat (✎)
├─────────────────────────────┤
│                             │
│  ┌──────────────────────┐   │
│  │ AI response bubble   │   │  ← left-aligned, neutral background
│  └──────────────────────┘   │
│                             │
│        ┌────────────────┐   │
│        │ User message   │   │  ← right-aligned, purple-tinted
│        └────────────────┘   │
│                             │
│  ┌──────────────────────┐   │
│  │ AI response with     │   │
│  │ action card inline   │   │
│  │ ┌──────────────────┐ │   │
│  │ │ ✅ Created task   │ │   │  ← action card embedded in response
│  │ │ [View in ToDo →] │ │   │
│  │ └──────────────────┘ │   │
│  └──────────────────────┘   │
│                             │
│  ● ● ●                     │  ← streaming indicator (typing dots)
│                             │
├─────────────────────────────┤
│ 🎤 │ Message Chat...│ ▶ │  ← input bar: mic, text field, send
└─────────────────────────────┘
```

- Messages scroll up; newest at bottom
- Input bar is pinned to the bottom and moves above the keyboard when active
- Auto-scrolls to bottom on new messages (unless user has scrolled up)
- Back button (≡) opens the conversation list as a pushed view
- New chat button (✎) starts a fresh conversation

### 2.2 iPad — Split View Chat

```
┌────────┬──────────────────┬─────────────────────┐
│        │  Chat    ✎   │                     │
│ 🧠 Chat│                  │                     │
│ 📋 Todo│  [AI bubble]     │  [Secondary Applet] │
│ 📅 Cal │                  │  (e.g. ToDo list)  │
│ 🏠 Home│  [User bubble]   │                     │
│        │                  │  Changes animate    │
│        │  [AI + card]     │  here in real time  │
│        │                  │  as Chat acts   │
│        │                  │                     │
│ ────── │──────────────────│                     │
│ ⚙ Set  │ 🎤 │ Message..│▶ │                     │
└────────┴──────────────────┴─────────────────────┘
```

- Chat can be the **primary panel** (full-width or left side of split)
- Chat can be the **secondary panel** (pinned alongside another applet)
- Conversation list is accessible via the sidebar — tapping "Chat" reveals recent conversations in an inline list or popover
- In split view, when Chat performs an action on the applet visible in the other panel, the change animates simultaneously

### 2.3 macOS — Resizable Chat Panel

```
┌──────────────────────────────────────────────────┐
│ ◀ ▶   Super                        🔔  ⚙  👤 │
├────────┬───────────────────┬─────────────────────┤
│        │  Chat     ✎   │                     │
│ 🧠 Chat│                   │                     │
│ 📋 Todo│  [AI bubble]      │ [Secondary Applet]  │
│ 📅 Cal │  [User bubble]    │                     │
│ 🏠 Home│  [AI + card]      │                     │
│        │                   │                     │
│        │                   │                     │
│ ────── │───────────────────│                     │
│ ⚙ Set  │ 🎤│ Message... │▶  │                     │
└────────┴───────────────────┴─────────────────────┘
```

- Chat panel is resizable — user drags the divider
- Minimum width: 320pt (ensures bubbles remain readable)
- Keyboard shortcut: `Cmd+Return` to send message
- Conversation list appears in a sidebar sub-panel or popover from the title area
- Supports multiple windows — user can detach Chat into its own window

### 2.4 Message Input Bar

The input bar is consistent across all platforms:

```
┌───┬──────────────────────────────┬───┐
│ 🎤│  Message Chat...         │ ▶ │
└───┴──────────────────────────────┴───┘
  │              │                   │
  mic          text field          send
```

- **Text field:** Multi-line, grows up to 5 lines before scrolling internally. Placeholder text: "Message Chat..."
- **Send button (▶):** Enabled only when text is non-empty or voice input is active. Purple-filled when active, gray when disabled.
- **Mic button (🎤):** Tap to toggle voice input. Pulsing animation when listening. Long-press for push-to-talk mode.
- **Attachment button (📎):** Future — for attaching images or files to the conversation. Hidden until the feature ships.

**Keyboard handling:**
- Input bar animates above the software keyboard with matching animation curve
- Content inset adjusts so messages remain visible
- `Return` key inserts a newline; `Cmd+Return` (Mac) or the send button submits
- On iPhone, a "Done" accessory button dismisses the keyboard without sending

---

## 3. Message Types & Bubbles

### 3.1 User Message

```
                    ┌────────────────────┐
                    │ Buy groceries and  │
                    │ pick up laundry    │
                    └────────────────────┘
                               12:34 PM ←  timestamp below bubble
```

- Right-aligned
- Purple-tinted background (lighter in light mode, deeper in dark mode)
- White or primary-label text
- Rounded corners (20pt radius, tail on bottom-right)
- Timestamp shown below the bubble, right-aligned, secondary label color

### 3.2 AI Text Response

```
┌────────────────────────────┐
│ Sure! I've added "Buy      │
│ groceries" to your tasks.  │
│                            │
│ Here's what I did:         │
│ - Created task with medium │
│   priority                 │
│ - Set due date to today    │
└────────────────────────────┘
12:34 PM
```

- Left-aligned
- Neutral background (secondary system background)
- Primary-label text
- Rounded corners (20pt radius, tail on bottom-left)
- Supports full markdown rendering:
  - **Bold**, *italic*, ~~strikethrough~~
  - Bullet and numbered lists
  - `inline code` and fenced code blocks with syntax highlighting
  - Headers (rendered as bold with increased size, not full-size headers)
  - Links (tappable, open in-app browser or deep link)
  - Tables (horizontally scrollable if wider than bubble)

### 3.3 Streaming Indicator

Before tokens arrive:
```
┌──────────┐
│  ● ● ●   │   ← three dots with sequential fade animation
└──────────┘
```

Once streaming begins, the dots transition into the first tokens of text. The bubble grows as more text arrives. See Section 4 for streaming behavior details.

### 3.4 Action Card

Shown inline within an AI response when Chat executes a tool call.

```
┌────────────────────────────────────────┐
│ ┌────────────────────────────────────┐ │
│ │ ✅  Created task: "Buy groceries"  │ │
│ │     Priority: Medium · Due: Today  │ │
│ │                                    │ │
│ │ [View in ToDo →]     [↩ Undo]    │ │
│ └────────────────────────────────────┘ │
│                                        │
│ I've added it to your default list.    │
└────────────────────────────────────────┘
```

Card anatomy:
- **Status icon:** Spinner (pending) → Checkmark (success) → X-mark (failure), colored by target applet's accent color
- **Tool icon + applet color:** e.g., blue checkmark for ToDo, orange calendar for Calendar, green house for Home
- **Description:** Brief summary of what was done ("Created task: Buy groceries")
- **Metadata:** Relevant details (priority, due date, device name, etc.)
- **Deep link button:** "View in ToDo →" — navigates to the result in the target applet
- **Undo button:** Shown for reversible actions. Tapping triggers an undo tool call.
- **Card background:** Slightly elevated from the message bubble (subtle shadow or border), using the target applet's accent color at 5-10% opacity

### 3.5 Suggestion Card

Shown for "Suggest & Confirm" responses where Chat proposes an action and waits for approval.

```
┌────────────────────────────────────────┐
│ I'd like to do the following:          │
│                                        │
│ ┌────────────────────────────────────┐ │
│ │ 📋 Create 4 tasks in "Home Reno"  │ │
│ │                                    │ │
│ │  · Paint bedroom                   │ │
│ │  · Fix kitchen faucet              │ │
│ │  · Replace bathroom mirror         │ │
│ │  · Install new light fixtures      │ │
│ │                                    │ │
│ │ [✓ Approve]  [✗ Reject]  [✎ Edit] │ │
│ └────────────────────────────────────┘ │
└────────────────────────────────────────┘
```

- **Approve button:** Green-tinted. Executes the proposed action. Card transitions to an action card with success/failure state.
- **Reject button:** Red-tinted. Dismisses the suggestion. Chat acknowledges inline ("Okay, I won't do that.").
- **Edit button:** Opens an inline editor where the user can modify the proposed items before approving. For example, remove a task from the batch or change a due date.
- For security-sensitive actions (e.g., locking doors via Home), the Approve button triggers biometric authentication (Face ID / Touch ID) before execution.

### 3.6 Error Card

Shown when a tool call fails.

```
┌────────────────────────────────────────┐
│ ┌────────────────────────────────────┐ │
│ │ ❌ Failed to create event          │ │
│ │    Calendar sync is unavailable    │ │
│ │                                    │ │
│ │ [↻ Retry]                         │ │
│ └────────────────────────────────────┘ │
│                                        │
│ Sorry, I couldn't add that event.      │
│ Would you like me to try again?        │
└────────────────────────────────────────┘
```

- Red-tinted status icon
- Brief error description (user-friendly, not raw error messages)
- Retry button when the error is transient
- Chat continues the conversation after the error, offering alternatives if possible

### 3.7 Multi-Tool Sequence

When Chat calls multiple tools in one turn (e.g., cross-applet chains), action cards stack vertically in execution order within the same response bubble.

```
┌────────────────────────────────────────┐
│ Setting up your vacation:              │
│                                        │
│ ┌────────────────────────────────────┐ │
│ │ ✅  Created event: "Vacation"      │ │
│ │     Mar 21 – Mar 28               │ │
│ └────────────────────────────────────┘ │
│ ┌────────────────────────────────────┐ │
│ │ ✅  Rescheduled 3 tasks to Mar 29  │ │
│ │     [View in ToDo →]             │ │
│ └────────────────────────────────────┘ │
│ ┌────────────────────────────────────┐ │
│ │ ✅  Activated "Away" scene         │ │
│ │     Lights off, thermostat 65°    │ │
│ └────────────────────────────────────┘ │
│                                        │
│ You're all set for vacation!           │
└────────────────────────────────────────┘
```

Cards appear sequentially as each tool executes — not all at once. This gives a satisfying cascade effect and lets the user follow what's happening step by step.

---

## 4. Streaming Text Rendering

### 4.1 Token Rendering

- Tokens render in small chunks (typically 1-4 tokens at a time) as they arrive from the LLM API
- Each chunk fades in with a subtle opacity animation (0 → 1 over 50ms)
- The message bubble grows smoothly as text is added (animated height change)
- When Reduce Motion is enabled, tokens appear instantly without fade animation

### 4.2 Incremental Markdown Parsing

- Markdown is parsed incrementally as tokens arrive
- Partial code blocks render with syntax highlighting as they stream — the opening ``` triggers a code block container immediately
- Partial bold/italic markers are held until the closing marker arrives (no flickering between states)
- Lists render each item as it completes
- The parser maintains state across chunks to handle split tokens correctly

### 4.3 Scroll Behavior During Streaming

- If the user is at the bottom of the chat, auto-scroll follows the streaming text
- If the user has scrolled up to read earlier messages, streaming continues but does NOT force-scroll to the bottom
- A "Jump to bottom" pill button appears when the user is scrolled up during streaming: `[↓ New messages]`
- Tapping the pill scrolls to the bottom with a smooth animation

### 4.4 Cancel & Interrupt

- A **Cancel button** (X) appears next to the streaming indicator during an active response
- Tapping Cancel sends a stop signal to the LLM API and finalizes the partial response as-is
- If the user sends a new message while streaming, the current response is finalized (not discarded) and the new message is sent as the next turn
- Finalized partial responses are stored in conversation history like complete responses

---

## 5. Tool Call UX Flow

### 5.1 Standard Tool Execution (Non-Destructive)

```
User sends message
        │
        ▼
LLM decides to call a tool
        │
        ▼
Action card appears → [⏳ Pending]
        │
        ▼
Tool executes locally (typically <100ms for GRDB writes)
        │
        ▼
Card transitions → [✅ Success] with result summary
        │
        ▼
If split view: target applet animates the change simultaneously
        │
        ▼
LLM continues response with tool result in context
```

The entire flow from tool call decision to success card typically takes under 200ms for local operations. The user experiences it as nearly instant.

### 5.2 Destructive / Confirmation-Required Tools

Tools flagged with `requiresConfirmation: true` follow a different flow:

```
User sends message
        │
        ▼
LLM decides to call a destructive tool
        │
        ▼
Suggestion card appears with proposed action
        │
        ├── User taps [Approve] ──────────────────────┐
        │                                              │
        ├── User taps [Approve] (biometric required) ──┤
        │       │                                      │
        │       ▼                                      │
        │   Face ID / Touch ID prompt                  │
        │       │                                      │
        │       ▼ (success)                            │
        │                                              ▼
        │                                   Tool executes
        │                                        │
        │                                        ▼
        │                            Action card [✅ Success]
        │                                        │
        │                                        ▼
        │                            LLM continues response
        │
        ├── User taps [Reject] ───→ LLM acknowledges, conversation continues
        │
        └── User taps [Edit] ────→ Inline editor → modified [Approve]
```

Biometric authentication is required for security-sensitive actions:
- Locking/unlocking doors (Home)
- Arming/disarming security systems (Home)
- Financial transactions (Money, future)

### 5.3 Multi-Tool Execution

When the LLM returns multiple tool calls in a single response:

1. Cards appear in sequence, one at a time, as each tool executes
2. Each card goes through the pending → success/failure lifecycle independently
3. If one tool fails, subsequent tools still execute (unless they depend on the failed tool's output)
4. If a tool in the chain requires confirmation, execution pauses at the suggestion card and resumes after approval
5. The LLM's final text response appears after all tool calls complete

### 5.4 Split View Coordination

When Chat and a target applet are both visible in split view:

- The action card shows the result in the chat panel
- Simultaneously, the target applet panel reflects the change with an animation (e.g., a new task slides into the ToDo list, a new event appears on the Calendar timeline)
- This synchronized animation is the signature "wow" interaction of Super
- If the target applet is NOT visible, a floating toast banner appears at the top: "Task created in ToDo — [View →]"

---

## 6. Conversation Management

### 6.1 Conversation List

**iPhone:** Full-screen list pushed from the chat view via the menu (≡) button.

```
┌─────────────────────────────┐
│  ← Conversations        ✎  │
├─────────────────────────────┤
│                             │
│  Morning briefing           │
│  "Here's your day..."       │
│  Today, 8:12 AM             │
│                             │
│  Home setup help            │
│  "I configured the..."      │
│  Yesterday, 9:45 PM         │
│                             │
│  Vacation planning          │
│  "I'll reschedule your..."  │
│  Mar 14, 3:22 PM            │
│                             │
│  Task breakdown             │
│  "Here are the subtasks..." │
│  Mar 13, 11:00 AM           │
│                             │
└─────────────────────────────┘
```

**iPad/Mac:** Sidebar sub-panel or popover showing the conversation list inline.

Each conversation row shows:
- **Title** — auto-generated from the first user message, editable via long-press/right-click
- **Preview** — first line of the most recent AI response, truncated
- **Date** — relative ("Today, 8:12 AM") or absolute ("Mar 14, 3:22 PM")

### 6.2 Conversation Actions

- **New conversation:** Tap the compose button (✎). The current conversation is preserved. A new empty chat opens.
- **Delete conversation:** Swipe left (iOS) or right-click > Delete (Mac). Confirmation alert: "Delete this conversation? This cannot be undone."
- **Rename conversation:** Long-press the title (iOS) or double-click (Mac) to edit the auto-generated title.
- **Search:** Search bar at the top of the conversation list. Searches across all conversations by message content. Results show matching messages with their conversation title and date.

### 6.3 Context Indicator

At the top of the chat, a subtle horizontal strip shows which applets are currently available to Chat:

```
┌─────────────────────────────────────┐
│  Available: 📋 📅 🏠 🔔             │  ← applet icons, dimmed style
└─────────────────────────────────────┘
```

- Shows icons of all installed applets whose tools are registered
- Tapping an icon navigates to that applet
- If an applet is unavailable (e.g., LLM provider not configured), its icon is grayed out with a warning badge
- This strip is collapsible — tapping it toggles between expanded (icons + labels) and collapsed (icons only) or hidden

---

## 7. System Prompt & Context Construction

The system prompt is invisible to the user but critical for Chat's behavior. It is constructed dynamically before each LLM call.

### 7.1 System Prompt Structure

```
1. Role definition
   "You are Chat, the AI assistant for Super..."

2. Available tools
   - List of all registered tools from active applets
   - Each tool includes: name, description, parameters, requiresConfirmation flag

3. Current context
   - Current date and time
   - User's timezone
   - Active applets list

4. Recent activity summary (optional, togglable in settings)
   - Last 3-5 significant events across applets
   - e.g., "User completed 2 tasks today", "Next event: Meeting at 3pm"

5. Behavioral instructions
   - Response type guidelines (when to Do & Confirm vs. Suggest & Confirm)
   - Deep linking format
   - Error handling instructions
```

### 7.2 Context Window Management

- System prompt + tools are always included (fixed cost)
- Conversation history: send the most recent N messages that fit within the context window
- Older messages are truncated from the beginning of the conversation
- If a conversation is very long, a summary of earlier turns is prepended before the recent messages
- Tool results are included in history as assistant/tool message pairs

---

## 8. Voice Input / Output

### 8.1 Voice Input

- **Tap mic button:** Toggles listening on/off. Mic icon pulses with a purple glow while listening.
- **Long-press mic button:** Push-to-talk mode. Listening stops when the user lifts their finger.
- **Hands-free mode:** Toggled in settings. Chat listens continuously after wake word or button press, with silence detection to auto-send.

Visual states:

```
Idle:        🎤  (static mic icon, gray)
Listening:   🎤  (pulsing purple glow, waveform animation in input bar)
Processing:  🎤  (spinner replaces waveform while speech-to-text processes)
```

- Uses Apple Speech framework (`SFSpeechRecognizer`) for on-device speech-to-text
- Transcribed text appears in the input field in real time as the user speaks
- User can edit the transcription before sending
- Language detection follows system locale

### 8.2 Voice Output

- Uses `AVSpeechSynthesizer` for text-to-speech
- A speaker icon (🔊) appears on each AI response bubble — tap to read that message aloud
- **Auto-read mode** (toggled in settings): Chat automatically reads responses aloud after streaming completes
- During voice output, a "Stop" button appears to cancel reading
- Voice output pauses if the user starts typing or taps the mic

### 8.3 Accessibility Interaction

- Voice input is compatible with Switch Control — the mic button is focusable
- VoiceOver users can activate the mic via the accessibility action
- Voice output uses the system's preferred voice and rate settings from Accessibility preferences

---

## 9. Settings (Chat-Specific)

Accessible from a gear icon in Chat's title bar or from the shell's per-applet settings section.

```
┌─────────────────────────────────┐
│  Chat Settings              │
├─────────────────────────────────┤
│                                 │
│  LLM PROVIDER                  │
│  ┌───────────────────────────┐  │
│  │ Provider: Claude       ▼ │  │  ← read from server config
│  │ Status: Connected ●      │  │
│  └───────────────────────────┘  │
│                                 │
│  CONVERSATION HISTORY           │
│  ┌───────────────────────────┐  │
│  │ Auto-delete after: Never▼│  │  ← Never / 7d / 30d / 90d
│  │ Delete All Conversations  │  │
│  └───────────────────────────┘  │
│                                 │
│  VOICE                          │
│  ┌───────────────────────────┐  │
│  │ Auto-read responses  [•] │  │
│  │ Voice: Samantha       ▼  │  │
│  │ Hands-free mode      [ ] │  │
│  └───────────────────────────┘  │
│                                 │
│  CONTEXT                        │
│  ┌───────────────────────────┐  │
│  │ Include activity       [•]│  │  ← recent activity summary in system prompt
│  │ summary in context        │  │
│  └───────────────────────────┘  │
│                                 │
│  TOOL CONFIRMATIONS             │
│  ┌───────────────────────────┐  │
│  │ Require confirmation for: │  │
│  │  ● Destructive only       │  │  ← default
│  │  ○ All actions            │  │
│  │  ○ Never (skip confirms)  │  │
│  └───────────────────────────┘  │
│                                 │
└─────────────────────────────────┘
```

- **LLM provider:** Read from server configuration (the backend proxies all LLM calls). Shows connection status. If the provider is not configured, shows an error with a link to the admin dashboard.
- **Conversation history:** Controls how long conversations are retained locally. "Delete All" requires confirmation.
- **Voice:** Auto-read toggle, voice selection (maps to `AVSpeechSynthesisVoice` options), hands-free mode toggle.
- **Context:** Whether Chat includes a brief recent-activity summary in the system prompt for better contextual answers.
- **Tool confirmations:** Controls which tool calls require user approval. "Destructive only" is the default and recommended setting. "Never" is a power-user option that skips all confirmation steps (with a warning that this includes security-sensitive actions).

---

## 10. Empty State & First Run

### 10.1 First Open

When Chat has no conversation history:

```
┌─────────────────────────────┐
│                             │
│                             │
│          🧠                 │
│       Chat              │
│                             │
│   Your AI assistant for     │
│   everything in Super.   │
│                             │
│   Try asking:               │
│                             │
│   ┌───────────────────────┐ │
│   │ "What can you do?"    │ │  ← tappable suggestion chip
│   └───────────────────────┘ │
│   ┌───────────────────────┐ │
│   │ "Show me my tasks     │ │
│   │  for today"           │ │
│   └───────────────────────┘ │
│   ┌───────────────────────┐ │
│   │ "Give me a morning    │ │
│   │  briefing"            │ │
│   └───────────────────────┘ │
│                             │
├─────────────────────────────┤
│ 🎤 │ Message Chat...│ ▶ │
└─────────────────────────────┘
```

- Large brain icon, centered, muted purple
- Brief tagline
- 3-4 tappable suggestion chips that populate the input field and auto-send
- Suggestion chips are contextual: if no applets are installed besides Chat, the first chip is "Help me set up Super"

### 10.2 LLM Provider Not Configured

If the backend has no LLM provider configured:

```
┌─────────────────────────────┐
│                             │
│          🧠                 │
│       Chat              │
│                             │
│   ⚠ LLM provider not       │
│     configured              │
│                             │
│   Chat needs an AI      │
│   provider to work. Ask     │
│   your admin to configure   │
│   one in the dashboard.     │
│                             │
│   [Open Admin Dashboard →]  │
│                             │
└─────────────────────────────┘
```

- Input bar is disabled (grayed out)
- Clear explanation and call to action
- This state is checked on each app launch and when the user navigates to Chat

### 10.3 No Active Applets

If Chat is the only installed applet (all others removed):

- Chat still works for general conversation
- Suggestion chips change to: "Add more applets to unlock my full potential" → links to Applet Manager
- The context indicator shows no applet icons

---

## 11. Accessibility

### 11.1 VoiceOver

- **User message bubbles:** Announced as "You said: [message text]"
- **AI response bubbles:** Announced as "Chat said: [message text]"
- **Action cards:** Announced as "[Status]: [description]. [Buttons available]" — e.g., "Success: Created task Buy groceries. Actions available: View in ToDo, Undo."
- **Status changes:** When an action card transitions from pending to success/failure, VoiceOver announces the change: "Task created successfully."
- **Streaming text:** VoiceOver waits until streaming completes before announcing the full response (does not read partial text)
- **Suggestion cards:** Announced as "Chat suggests: [action]. Actions available: Approve, Reject, Edit."

### 11.2 Dynamic Type

- All message text, card content, and UI labels respect the system Dynamic Type setting
- Message bubbles resize to accommodate larger text
- At the largest accessibility text sizes, the input bar expands vertically and buttons increase tap target size to 44x44pt minimum
- Suggestion chips in the empty state wrap to multiple lines

### 11.3 Reduce Motion

When Reduce Motion is enabled:
- Streaming text appears instantly (no character-by-character fade)
- Action cards appear fully formed (no expand-from-dot animation)
- Tool execution shows a static checkmark instead of spinner → checkmark spring animation
- Message send/receive uses simple opacity fade instead of slide animations
- Conversation switch is a cut instead of crossfade

### 11.4 Other

- All interactive elements meet minimum 44x44pt touch targets
- Color is never the sole indicator of status — icons and text labels accompany all colored states
- Voice input works with Switch Control via the standard accessibility action interface
- High contrast mode: message bubbles gain a subtle border for better delineation

---

## 12. Animations

### 12.1 Message Animations

| Event | Animation | Duration | Curve |
|-------|-----------|----------|-------|
| User sends message | Bubble slides up from input bar position | 250ms | easeOut |
| AI response appears | Bubble fades in from left (opacity 0→1, slight x-offset) | 200ms | easeOut |
| Streaming text | Each token chunk fades in (opacity 0→1) | 50ms | linear |

### 12.2 Card Animations

| Event | Animation | Duration | Curve |
|-------|-----------|----------|-------|
| Action card appears | Expands from a small dot to full size | 300ms | spring (damping 0.7) |
| Pending → Success | Spinner morphs to checkmark | 400ms | spring (damping 0.6) |
| Pending → Failure | Spinner morphs to X-mark, card border flashes red | 300ms | easeOut |
| Suggestion card buttons | Buttons scale down on press (0.95), spring back on release | 150ms | spring |

### 12.3 Navigation Animations

| Event | Animation | Duration | Curve |
|-------|-----------|----------|-------|
| Open conversation list | Standard push navigation (iPhone) or sidebar reveal (iPad/Mac) | System default | System default |
| Switch conversation | Messages crossfade | 200ms | easeInOut |
| New conversation | Chat area clears with a downward fade, empty state fades in | 300ms | easeOut |

### 12.4 Voice Animations

| Event | Animation | Duration | Curve |
|-------|-----------|----------|-------|
| Mic listening | Purple glow pulses around mic icon | 1200ms loop | easeInOut |
| Voice waveform | Audio-reactive bars in the input field | Continuous | linear |
| Speech processing | Waveform morphs to a horizontal spinner | 200ms | easeInOut |

---

## 13. Design Tokens Reference

For consistency, Chat uses these design values (inheriting from the shell's shared design system):

| Token | Value |
|-------|-------|
| Accent color | `Color.purple` (system purple) |
| User bubble background | `purple.opacity(0.15)` (light) / `purple.opacity(0.3)` (dark) |
| AI bubble background | `Color(.secondarySystemBackground)` |
| Card background | `Color(.tertiarySystemBackground)` |
| Card border (success) | Target applet's accent color at 30% opacity |
| Card border (error) | `Color.red.opacity(0.3)` |
| Bubble corner radius | 20pt |
| Card corner radius | 12pt |
| Input bar height | 48pt (minimum), grows with content |
| Spacing between messages | 8pt (same sender), 16pt (different sender) |
| Max bubble width | 80% of chat area width |
| Font — message text | `.body` (Dynamic Type) |
| Font — card title | `.subheadline.weight(.semibold)` |
| Font — card metadata | `.caption` |
| Font — timestamp | `.caption2`, secondary label color |
