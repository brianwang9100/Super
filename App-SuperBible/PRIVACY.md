# SuperBible — Privacy

**Last updated: 2026-05-23**

SuperBible is a free, open-source AI Bible app. We — actually, **I**: SuperBible is built by a solo developer — try to operate on a simple principle: **your study is yours.** This page is the plain-English explanation of what that means.

If you'd rather read the source: every claim below is backed by the code in this repository, which is public on GitHub. Nothing here is a marketing promise — it's a description of how the app actually works.

---

## What SuperBible does NOT collect

Ever. Not opt-in, not opt-out, not "anonymized" — not collected at all by SuperBible:

- **The verses you read.** Reading position, scroll position, time spent on a chapter — none of it leaves your device.
- **Your highlights, notes, and bookmarks.** Stored locally on your device only — including notes the AI assistant writes for you (when you ask it to), which are saved to the same on-device database and never leave your device.
- **Your reading-plan progress.** Which plan you picked, which days you completed, your streak — all on-device only.
- **Your identity.** No accounts. No email. No username. No sign-in. No "anonymous ID" tied to your device.
- **Your location.** Never requested, never accessed.
- **Your contacts, photos, calendar, or any other personal data on your device.** Not requested, not accessed.
- **What other apps you use, when, or how often.** Not accessed.
- **Your voice.** When you dictate a chat message, SuperBible uses Apple's **on-device** speech recognition (`requiresOnDeviceRecognition = true`) — the audio and the transcript are processed entirely on your iPhone or iPad and are never uploaded to Apple or to us. The microphone is used only while you're actively dictating.

### About your chat messages — be aware of where they go

Chat messages need separate treatment because **where they go depends on which AI model you're using**, and SuperBible cannot collect them but a third-party AI provider might:

- **Apple Foundation Models (the default).** Runs entirely on-device. Your messages never leave your iPhone or iPad. SuperBible has no servers — even if we wanted to see your messages, there's no infrastructure for that.
- **Optional Bring Your Own Key (BYOK) — Anthropic, OpenAI, a local Ollama server, etc.** When you configure an API key in Settings → Models and then chat, your messages are sent **directly from your device to that provider over HTTPS**. SuperBible's code (we have no servers) is not in that loop. Whatever the provider does with your message — log it, train on it, keep it for 30 days, delete it — is governed by **their** privacy policy, not ours. We strongly recommend you read it before adding their key.

This is why we say "BYOK" plainly throughout the app: the key (and the data flowing through it) is yours, and the relationship is between you and the provider you chose.

---

## What SuperBible DOES do with data

### On your device

Everything. Your Bible highlights, notes, reading-plan progress, memorize cards (when that mini-app ships), and chat history all live in a local database on your device. They're backed up to iCloud only if you've enabled iCloud Backup for SuperBible in iOS Settings.

### When you chat with the AI

SuperBible's default AI model is **Apple Foundation Models**, which runs entirely on-device. When you use it, no data leaves your device.

If you optionally configure a third-party AI provider (OpenAI, Anthropic, a local Ollama server, etc.) by adding their API key in Settings → Models, then your chat messages are sent **directly from your device to that provider** when you chat. SuperBible's servers (we don't have any) are not in that loop. The provider's privacy policy governs what they do with the data — that's between you and them, not us.

API keys are stored in the iOS Keychain (the same place iOS stores your Wi-Fi passwords), with the **`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`** accessibility attribute. That means: only readable while the device is unlocked, and **never** included in iCloud Keychain sync or device-to-device migration. They live on this device, this install, and nowhere else.

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

SuperBible doesn't collect anything from anyone, so it doesn't knowingly collect anything from children either.

The app's default AI model is **Apple Foundation Models**, which runs entirely on-device — no internet connection is required for chat to work out of the box. If a parent later configures a third-party AI provider via Settings → Models (BYOK), chat messages would then travel from the device to that provider, governed by *their* privacy policy. We have no control over what those providers do.

---

## Changes

If this policy changes, the new version replaces this file in the repository and the "Last updated" date at the top changes. The git history of this file shows every change.

---

## Questions

Open an issue at https://github.com/brianwang9100/Super/issues or email brianwang9100@gmail.com.
