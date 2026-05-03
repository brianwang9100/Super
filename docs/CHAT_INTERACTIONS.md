# Super: Chat Interactions Catalog

> User stories for how Chat orchestrates actions across applets — the "universal remote" for your life.

> **Status (2026-05-03):** Aspirational — only the Chat applet exists today, plus one built-in tool (`time.now`). Cross-applet interactions described below land as their target applets do. Tracked in [`TODO.md`](../TODO.md) § Other applets and § Cross-applet plumbing.

---

## 1. Purpose

This document catalogs every type of interaction where a user talks to Chat and something happens in another applet. Each interaction defines:

- **Trigger** — what the user says (natural language)
- **Action** — what Chat does (tool call, deep link, or both)
- **Response type** — how the user sees the result
- **Applets involved** — which applets participate

### Response Types

| Type | Description | When to Use |
|------|-------------|-------------|
| **Do & Confirm** | Chat performs the action and shows an inline confirmation card in chat. If the target applet is visible (split view), the change animates in. | Simple actions with no ambiguity — the user clearly said what to do |
| **Do & Deep Link** | Chat performs the action and offers a button to jump to the result in the target applet. | When the user likely wants to see or refine the result |
| **Query & Answer** | Chat fetches data from an applet and answers inline — no navigation needed. | Read-only questions |
| **Query & Deep Link** | Chat answers the question and offers a link to the relevant screen for more detail. | When the answer is a summary and the user might want the full view |
| **Suggest & Confirm** | Chat proposes an action and waits for the user to approve before executing. | Destructive, expensive, or ambiguous actions |
| **Navigate Only** | Chat deep links to the right screen without performing an action. | "Show me X" / "Open Y" / "Go to Z" |

---

## 2. Chat → ToDo (Todos)

### 2.1 Create Tasks

| # | User Says | Action | Response | Notes |
|---|-----------|--------|----------|-------|
| 1 | "Add a task to buy groceries" | `todo.create(title: "Buy groceries")` | Do & Confirm | Simplest case — inline card shows the created task |
| 2 | "Remind me to call the dentist tomorrow, high priority" | `todo.create(title: "Call the dentist", priority: .high, dueDate: tomorrow)` | Do & Confirm | Parses priority and date from natural language |
| 3 | "Break down 'redesign landing page' into subtasks" | `todo.get(title: "redesign landing page")` → AI generates subtasks → `todo.createSubtasks(parentId, subtasks)` | Do & Deep Link | Multi-step: fetches parent task, generates breakdown, creates subtasks, links to task detail view |
| 4 | "Add these tasks to my Home Renovation project: paint bedroom, fix kitchen faucet, replace bathroom mirror" | `todo.createBatch(project: "Home Renovation", tasks: [...])` | Do & Deep Link | Batch creation — link opens the project view |
| 5 | "I need to prepare for my presentation on Friday" | AI generates a task list based on context → `todo.createBatch(...)` | Suggest & Confirm | Ambiguous — AI proposes tasks, user reviews before creation |

### 2.2 Query Tasks

| # | User Says | Action | Response | Notes |
|---|-----------|--------|----------|-------|
| 6 | "What's on my plate today?" | `todo.list(dueDate: today)` | Query & Answer | Lists tasks due today inline |
| 7 | "How many overdue tasks do I have?" | `todo.count(filter: overdue)` | Query & Answer | Simple count response |
| 8 | "Show me my Home Renovation project" | None — navigation only | Navigate Only | Deep links to the project board view |
| 9 | "What did I get done this week?" | `todo.list(status: .done, completedSince: startOfWeek)` | Query & Deep Link | Shows summary inline, links to filtered done list |

### 2.3 Update Tasks

| # | User Says | Action | Response | Notes |
|---|-----------|--------|----------|-------|
| 10 | "Mark 'buy groceries' as done" | `todo.update(title: "buy groceries", status: .done)` | Do & Confirm | Checkmark animation in chat card |
| 11 | "Move all my low priority tasks to backlog" | `todo.batchUpdate(filter: {priority: .low}, status: .backlog)` | Suggest & Confirm | Batch update — confirm before executing |
| 12 | "Push my dentist reminder to next week" | `todo.update(title: "dentist", dueDate: nextWeek)` | Do & Confirm | Date rescheduling |
| 13 | "Bump 'fix login bug' to urgent" | `todo.update(title: "fix login bug", priority: .urgent)` | Do & Confirm | Priority change |

---

## 3. Chat → Calendar (Calendar)

### 3.1 Create Events

| # | User Says | Action | Response | Notes |
|---|-----------|--------|----------|-------|
| 14 | "Schedule a meeting with Sarah tomorrow at 2pm for an hour" | `calendar.create(title: "Meeting with Sarah", start: tomorrow 2pm, end: tomorrow 3pm)` | Do & Deep Link | Links to the day view showing the new event |
| 15 | "Block off Friday afternoon for deep work" | `calendar.create(title: "Deep Work", start: Friday 12pm, end: Friday 5pm, category: .focus)` | Do & Confirm | Time blocking |
| 16 | "I have a dentist appointment next Tuesday from 10 to 11:30" | `calendar.create(title: "Dentist", start: nextTuesday 10am, end: nextTuesday 11:30am)` | Do & Confirm | Basic event creation |
| 17 | "Set up a recurring standup every weekday at 9am, 15 minutes" | `calendar.create(title: "Standup", start: 9am, duration: 15m, recurrence: .weekdays)` | Do & Confirm | Recurring event |

### 3.2 Query Calendar

| # | User Says | Action | Response | Notes |
|---|-----------|--------|----------|-------|
| 18 | "What does my week look like?" | `calendar.list(range: thisWeek)` | Query & Deep Link | Summary inline, link to week view |
| 19 | "Am I free Thursday afternoon?" | `calendar.checkAvailability(date: Thursday, range: 12pm-6pm)` | Query & Answer | Simple yes/no with details |
| 20 | "When's my next meeting?" | `calendar.next(type: .meeting)` | Query & Answer | Shows next event inline |
| 21 | "How many hours of meetings do I have this week?" | `calendar.aggregate(type: .meeting, range: thisWeek, metric: .totalDuration)` | Query & Answer | Analytical query |

### 3.3 Modify Events

| # | User Says | Action | Response | Notes |
|---|-----------|--------|----------|-------|
| 22 | "Move my 2pm to 3pm" | `calendar.update(match: "2pm today", newStart: 3pm)` | Do & Confirm | Context-aware — infers today's 2pm event |
| 23 | "Cancel my Friday standup" | `calendar.delete(match: "standup Friday")` | Suggest & Confirm | Deletion — confirm first. Also: delete just this instance or all recurring? |
| 24 | "Clear my afternoon, I need to focus" | `calendar.list(range: todayAfternoon)` → show what would be cancelled | Suggest & Confirm | Destructive batch — show what would be affected, confirm |

---

## 4. Chat → Home (Home)

### 4.1 Device Control

| # | User Says | Action | Response | Notes |
|---|-----------|--------|----------|-------|
| 25 | "Turn off the living room lights" | `home.setDevice(room: "living room", type: .light, state: .off)` | Do & Confirm | Light icon dims in chat card |
| 26 | "Set the thermostat to 72" | `home.setTemperature(zone: "main", temp: 72)` | Do & Confirm | Thermostat dial animation in chat card |
| 27 | "Lock the front door" | `home.setDevice(id: "front_door_lock", state: .locked)` | Suggest & Confirm (biometric) | Security-sensitive — requires Face ID / Touch ID confirmation |
| 28 | "Dim the bedroom lights to 30%" | `home.setDevice(room: "bedroom", type: .light, brightness: 0.3)` | Do & Confirm | Partial state change |
| 29 | "Is the garage door open?" | `home.getStatus(device: "garage_door")` | Query & Answer | Status check |

### 4.2 Scenes

| # | User Says | Action | Response | Notes |
|---|-----------|--------|----------|-------|
| 30 | "Movie time" | `home.activateScene("Movie Night")` | Do & Confirm | Cascade animation: lights dim, TV turns on, etc. |
| 31 | "I'm leaving the house" | `home.activateScene("Away")` | Suggest & Confirm | May lock doors, arm security — confirm first |
| 32 | "Good morning" | `home.activateScene("Good Morning")` | Do & Confirm | Lights on, coffee maker starts, etc. |
| 33 | "Create a scene called 'Reading' that dims bedroom to 40% and turns off all other lights" | `home.createScene(name: "Reading", actions: [...])` | Do & Deep Link | Links to scene detail for review |

### 4.3 Status & Monitoring

| # | User Says | Action | Response | Notes |
|---|-----------|--------|----------|-------|
| 34 | "What's the temperature in the house?" | `home.getStatus(type: .thermostat)` | Query & Answer | Shows current temp per zone |
| 35 | "Are all the doors locked?" | `home.getStatus(type: .lock)` | Query & Answer | Security status check |
| 36 | "Show me the home dashboard" | None — navigation | Navigate Only | Deep links to Home root view |
| 37 | "What devices are on right now?" | `home.listDevices(filter: .on)` | Query & Deep Link | List inline, link to home dashboard |

---

## 5. Chat → Money (Finance — Future)

### 5.1 Balances & Accounts

| # | User Says | Action | Response | Notes |
|---|-----------|--------|----------|-------|
| 38 | "What's my checking account balance?" | `money.getBalance(account: "checking")` | Query & Answer | Shows balance inline — no full account number |
| 39 | "How much do I have across all accounts?" | `money.getBalance(all: true)` | Query & Answer | Aggregate balance summary |
| 40 | "Show me my accounts" | None — navigation | Navigate Only | Deep links to Money accounts overview |
| 41 | "How are my investments doing?" | `money.getPerformance(type: .investment, range: .ytd)` | Query & Deep Link | Summary inline, link to performance chart |

### 5.2 Transactions

| # | User Says | Action | Response | Notes |
|---|-----------|--------|----------|-------|
| 42 | "How much did I spend on restaurants this month?" | `money.aggregate(category: "restaurants", range: thisMonth, metric: .totalSpend)` | Query & Answer | Spending query |
| 43 | "Show me my recent Amazon transactions" | `money.searchTransactions(merchant: "Amazon", limit: 10)` | Query & Deep Link | List inline, link to filtered transaction view |
| 44 | "Tag all Uber transactions as 'commute'" | `money.tagTransactions(merchant: "Uber", tag: "commute")` | Suggest & Confirm | Batch tagging — confirm count before applying |
| 45 | "How much did I earn last month?" | `money.aggregate(type: .income, range: lastMonth)` | Query & Answer | Income query |
| 46 | "What's my biggest expense this week?" | `money.topTransactions(range: thisWeek, sort: .amount, limit: 1)` | Query & Answer | Analytical query |

### 5.3 Budgeting

| # | User Says | Action | Response | Notes |
|---|-----------|--------|----------|-------|
| 47 | "Am I over budget on dining out?" | `money.checkBudget(category: "dining")` | Query & Answer | Budget status check |
| 48 | "How much have I saved this year compared to last year?" | `money.compare(metric: .savings, periods: [thisYear, lastYear])` | Query & Deep Link | Comparison inline, link to savings chart |

---

## 6. Chat → Notifications (Notifications — Future)

| # | User Says | Action | Response | Notes |
|---|-----------|--------|----------|-------|
| 49 | "What notifications do I have?" | `alert.list(unread: true)` | Query & Deep Link | Summary inline, link to Notifications inbox |
| 50 | "Dismiss all low-priority notifications" | `alert.dismissBatch(priority: .low)` | Do & Confirm | Batch dismiss |
| 51 | "Snooze my overdue task reminders for an hour" | `alert.snooze(type: "task.overdue", duration: 1hr)` | Do & Confirm | Snooze |

---

## 7. Cross-Applet Chains

These are the interactions where Chat orchestrates across multiple applets in a single request. These are the "wow" moments.

### 8.1 Calendar + Todos

| # | User Says | Tool Calls | Response | Notes |
|---|-----------|-----------|----------|-------|
| 56 | "Schedule time to work on my urgent tasks this week" | `todo.list(priority: .urgent)` → `calendar.checkAvailability(thisWeek)` → `calendar.createBatch(timeBlocks)` | Suggest & Confirm | AI reads urgent tasks, finds open slots, proposes time blocks. User reviews before creation. |
| 57 | "I finished the presentation, mark it done and cancel the prep time on my calendar" | `todo.update("presentation", status: .done)` → `calendar.delete(match: "presentation prep")` | Do & Confirm | Two actions, one intent |
| 58 | "What's on my plate for tomorrow including events and tasks?" | `todo.list(dueDate: tomorrow)` + `calendar.list(date: tomorrow)` | Query & Answer | Unified daily briefing from two applets |

### 8.2 Todos + Money

| # | User Says | Tool Calls | Response | Notes |
|---|-----------|-----------|----------|-------|
| 59 | "Add 'pay rent' to my todos and remind me when my checking balance is above $3000" | `todo.create("Pay rent")` → `alert.createConditional(condition: money.balance("checking") > 3000, action: notify("Pay rent"))` | Do & Confirm | Conditional cross-applet automation |
| 60 | "Create a task for every recurring bill I have" | `money.getRecurring()` → `todo.createBatch(tasks from recurring bills)` | Suggest & Confirm | Reads financial data, proposes tasks |

### 8.3 Home + Calendar

| # | User Says | Tool Calls | Response | Notes |
|---|-----------|-----------|----------|-------|
| 61 | "Warm up the house 30 minutes before I get home — check my calendar for when my last meeting ends" | `calendar.list(date: today)` → infer last meeting end → `home.scheduleTemperature(time: meetingEnd - 30m, temp: 72)` | Do & Confirm | Calendar-aware home automation |
| 62 | "When my 'Movie Night' calendar event starts, activate movie scene" | `alert.createAutomation(trigger: calendar.eventStart("Movie Night"), action: home.activateScene("Movie Night"))` | Do & Confirm | Event-triggered home automation |

### 8.4 Full Ecosystem

| # | User Says | Tool Calls | Response | Notes |
|---|-----------|-----------|----------|-------|
| 63 | "Give me a morning briefing" | `calendar.list(today)` + `todo.list(dueDate: today, priority: [.urgent, .high])` + `money.getBalance(all: true)` + `home.getStatus(type: .thermostat)` + `alert.list(unread: true)` | Query & Answer | The killer feature: one prompt, all your context |
| 64 | "I'm going on vacation for a week starting Saturday" | `calendar.create("Vacation", range: Saturday-nextSaturday)` + `todo.batchUpdate(dueDateInRange, newDueDate: postVacation)` + `home.activateScene("Away")` + `alert.snooze(all, duration: 1week)` | Suggest & Confirm | Multi-applet life event. AI proposes all changes, user reviews. |
| 65 | "End of day shutdown" | `todo.list(status: .inProgress)` → summarize progress + `home.activateScene("Night")` + `calendar.next(date: tomorrow, limit: 1)` → preview tomorrow | Query & Answer | Daily wind-down ritual |

---

## 8. Deep Linking Patterns

### 9.1 Deep Link Anatomy

Every applet screen must be addressable via a deep link URL scheme:

```
super://<applet>/<screen>?<params>

Examples:
super://todo/task?id=abc123
super://todo/project?name=Home+Renovation
super://todo/board?filter=urgent
super://calendar/day?date=2026-03-20
super://calendar/event?id=xyz789
super://home/room?name=Living+Room
super://home/device?id=front_door_lock
super://money/transactions?merchant=Amazon
super://money/account?id=checking
super://notifications/inbox
```

### 9.2 How Deep Links Work in Chat

When Chat performs an action or answers a query, the response card includes:

```
┌─────────────────────────────────────────┐
│ ✅ Task created: "Buy groceries"        │
│ Priority: Medium · Due: Tomorrow        │
│                                         │
│ [View in ToDo →]                       │  ← tappable deep link
└─────────────────────────────────────────┘
```

Tapping the link:
- **iPhone:** Switches to the ToDo tab and navigates to the relevant screen
- **iPad/Mac (split view):** Opens ToDo in the secondary panel if not already visible, navigates to the screen
- **iPad/Mac (ToDo already visible):** Scrolls/navigates to the item directly

### 9.3 "Show Me" / "Open" / "Go To" Commands

When the user's intent is purely navigational, Chat skips tool calls entirely and issues a deep link:

| User Says | Deep Link | Behavior |
|-----------|-----------|----------|
| "Show me my todos" | `super://todo/list` | Navigate to ToDo list view |
| "Open my calendar for next week" | `super://calendar/week?date=nextMonday` | Navigate to Calendar week view |
| "Go to my home dashboard" | `super://home/dashboard` | Navigate to Home root |
| "Open the transaction for my last Amazon purchase" | `money.searchTransactions(merchant: "Amazon", limit: 1)` → `super://money/transaction?id=result.id` | Query first to find the transaction, then deep link |

---

## 9. Notification & Proactive Interactions

These are cases where Chat or an applet initiates contact — the user didn't ask, but the system has something worth saying.

| # | Trigger | Notification | Action Available |
|---|---------|-------------|-----------------|
| 66 | Task due in 1 hour | "Reminder: 'Call dentist' is due in 1 hour" | [Mark Done] [Snooze 1hr] [Open →] |
| 67 | Calendar event in 15 min | "Meeting with Sarah starts in 15 minutes" | [Open Calendar →] |
| 68 | Home device anomaly | "Front door has been unlocked for 30 minutes" | [Lock Now] [Dismiss] [Open Home →] |
| 69 | Large transaction detected | "Unusual transaction: $847 at BestBuy" | [View Transaction →] [Tag It] |
| 70 | Budget threshold exceeded | "You've spent 90% of your dining budget this month" | [View Spending →] |

---

## 10. Interaction Design Principles

1. **Bias toward action.** If the user's intent is clear, do it and confirm. Don't ask "would you like me to create that task?" — just create it and show the confirmation card.

2. **Confirm destructive or ambiguous actions.** Deleting, batch-updating, or anything involving money/security gets a confirmation step.

3. **Always offer the deep link.** Even for simple actions, include a link to the result. The user might want to see it in context.

4. **Cross-applet actions should feel like one action.** "I'm going on vacation" triggers 4 applets, but the user experiences it as one confirmation card with a summary of all proposed changes.

5. **Fail gracefully across applets.** If a cross-applet chain partially fails (calendar event created but todo creation failed), report what succeeded and what didn't — don't roll back the successful parts.

6. **Context is king.** "Move my 2pm" — Chat should know today's schedule without the user specifying the date. "Is the door locked?" — Chat should know which door if there's only one lock.

---

## 11. Open Questions

1. **How does Chat handle ambiguity?** If "move my meeting" matches multiple events, does it ask "which one?" or show a picker?
2. **Should Chat support multi-turn tool use?** e.g., "Add a task" → "What's the title?" → "Buy milk" → "Priority?" → "Low". Or should it always try to infer from a single message?
3. **Undo support?** If Chat creates a task and the user says "undo that" — how deep does undo go? Just the last action? The whole cross-applet chain?
4. **Voice mode interactions?** When using voice input, should confirmations be voice-based too? Or always visual?
5. **Proactive suggestions — too annoying?** How aggressively should Chat suggest actions? "I notice you have 5 overdue tasks — want me to reschedule them?"
6. **Conversation context window?** How many previous messages does Chat send to the LLM? All of them? Last N? Summarized?
7. **Offline tool calls?** If Chat can't reach the LLM, can it still execute simple tool calls locally (e.g., via pattern matching)? Or does it just say "I'm offline"?
