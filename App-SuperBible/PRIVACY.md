# SuperBible — Privacy

**Last updated: 2026-05-23**

SuperBible is a free, open-source AI Bible app. We — actually, **I**: SuperBible is built by a solo developer — try to operate on a simple principle: **your study is yours.** This page is the plain-English explanation of what that means.

If you'd rather read the source: every claim below is backed by the code in this repository, which is public on GitHub. Nothing here is a marketing promise — it's a description of how the app actually works.

---

## What SuperBible does NOT collect

Ever. Not opt-in, not opt-out, not "anonymized" — not collected at all:

- **The verses you read.** Reading position, scroll position, time spent on a chapter — none of it leaves your device.
- **Your highlights, notes, and bookmarks.** Stored locally on your device only.
- **Your chat messages with the AI.** Neither the questions you ask nor the answers you receive are sent to SuperBible's servers (we don't have any).
- **Your reading-plan progress.** Which plan you picked, which days you completed, your streak — all on-device only.
- **Your identity.** No accounts. No email. No username. No sign-in. No "anonymous ID" tied to your device.
- **Your location.** Never requested, never accessed.
- **Your contacts, photos, calendar, or any other personal data on your device.** Not requested, not accessed.
- **What other apps you use, when, or how often.** Not accessed.

---

## What SuperBible DOES do with data

### On your device

Everything. Your Bible highlights, notes, reading-plan progress, memorize cards (when that mini-app ships), and chat history all live in a local database on your device. They're backed up to iCloud only if you've enabled iCloud Backup for SuperBible in iOS Settings.

### When you chat with the AI

SuperBible's default AI model is **Apple Foundation Models**, which runs entirely on-device. When you use it, no data leaves your device.

If you optionally configure a third-party AI provider (OpenAI, Anthropic, a local Ollama server, etc.) by adding their API key in Settings → Models, then your chat messages are sent **directly from your device to that provider** when you chat. SuperBible's servers (we don't have any) are not in that loop. The provider's privacy policy governs what they do with the data — that's between you and them, not us.

API keys are stored in the iOS Keychain (the same place iOS stores your Wi-Fi passwords). They never leave your device.

### Crash reports and diagnostics

If you've left **iOS Settings → Privacy & Security → Analytics & Improvements → Share with App Developers** turned on (it's on by default), then:

- When SuperBible crashes, iOS may send Apple a stack trace describing what code crashed.
- iOS may send Apple aggregated, anonymous performance data (app launch time, frame rate, memory usage) about how SuperBible behaves on your device.

Apple shares this with us through App Store Connect, **without** anything that could identify you. We see things like "this code crashed 12 times in the last 7 days" or "app launches take ~1.3s on iPhone 15 Pro" — not "Brian's iPhone crashed."

You can turn this off at any time in iOS Settings. Turning it off doesn't change anything about how SuperBible works.

### Install and version counts

Apple's App Store Connect tells us, in aggregate, how many people install SuperBible, how many return to it the next day, and which app version + iOS version + device family each install is on. This is anonymous and aggregated by Apple before we see it.

---

## What SuperBible does NOT use

- **No third-party analytics SDKs.** No PostHog. No Mixpanel. No Amplitude. No Firebase Analytics. None.
- **No third-party crash reporters.** No Sentry. No Crashlytics. No Bugsnag. None.
- **No advertising SDKs.** No Facebook SDK. No Google ads. None. SuperBible doesn't show ads.
- **No attribution SDKs.** No AppsFlyer. No Adjust. None.
- **No telemetry libraries.** No OpenTelemetry, Datadog, New Relic. None.

The complete list of third-party libraries SuperBible uses is visible in the repository's `Package.resolved` file. If you see something that looks suspicious, [open a GitHub issue](https://github.com/brianwang9100/Super/issues) — that's a bug.

---

## Money

SuperBible is **free**. There are no ads, no in-app purchases, no premium tier, no paywalls.

If you'd like to support development, there's a "Support development" link in Settings → About that opens GitHub Sponsors in a web view. That's the only place SuperBible asks you for money, and it's entirely optional.

---

## Children

SuperBible doesn't collect anything from anyone, so it doesn't knowingly collect anything from children either. The app does require an active connection to a third-party AI provider (or use of Apple Foundation Models on-device) for chat to work; we have no control over what those providers do.

---

## Changes

If this policy changes, the new version replaces this file in the repository and the "Last updated" date at the top changes. The git history of this file shows every change.

---

## Questions

Open an issue at https://github.com/brianwang9100/Super/issues or email brianwang9100@gmail.com.
