# SuperBible — Privacy

**Last updated: 2026-09-06**

SuperBible is a free, open-source AI Bible app. We — actually, **I**: SuperBible is built by a solo developer — try to operate on a simple principle: **your study is yours.** This page is the plain-English explanation of what that means.

If you'd rather read the source: every claim below is backed by the code in this repository, which is public on GitHub. Nothing here is a marketing promise — it's a description of how the app actually works.

---

## What SuperBible does NOT collect

Ever. Not opt-in, not opt-out, not "anonymized" — not collected at all by SuperBible:

- **Your reading activity.** We do not collect reading-position, scrolling, or time-spent analytics. Verses supplied to a chat are processed by its selected model, as described below.
- **Your highlights, notes, and bookmarks.** Saved in the on-device database, including AI-created notes. Content you include in a chat or expose through enabled AI tools can be processed by your selected model, including a cloud model.
- **Your reading-plan progress.** Which plan you picked, which days you completed, your streak — all on-device only.
- **Your identity.** No accounts. No email. No username. No sign-in. No "anonymous ID" tied to your device.
- **Your location.** Never requested, never accessed.
- **Your contacts, photos, calendar, or any other personal data on your device.** Not requested, not accessed.
- **What other apps you use, when, or how often.** Not accessed.
- **Your voice recordings.** Dictation uses Apple's **on-device** speech recognition (`requiresOnDeviceRecognition = true`). Audio is not uploaded; when you send the resulting text as a message, it follows the selected model's processing route below. The microphone is used only while you're actively dictating.

### About your chat messages — be aware of where they go

Chat messages need separate treatment because **where they go depends on which AI model you're using**, and SuperBible cannot collect them but a third-party AI provider might:

- **Apple Intelligence — Local only.** Model inference happens on your device. This is the fresh-setup default on iOS 26. Enabled tools may make separate network requests.
- **Apple Intelligence — Private Cloud Compute (PCC).** The fresh-setup default on iOS 27 or later. Messages, conversation context, and enabled tool results are sent through Apple's Foundation Models framework for processing on Apple's cloud infrastructure. This requires an eligible device, Apple Intelligence, internet access, and available usage quota. Learn about [Apple's Private Cloud Compute protections](https://security.apple.com/private-cloud-compute/).
- **Optional Bring Your Own Key (BYOK) — Anthropic, OpenAI, a local Ollama server, etc.** When you configure an API key in Settings → Models and then chat, your messages are sent **directly from your device to that provider over HTTPS**. SuperBible's code (we have no servers) is not in that loop. Whatever the provider does with your message — log it, train on it, keep it for 30 days, delete it — is governed by **their** privacy policy, not ours. We strongly recommend you read it before adding their key.

This is why we say "BYOK" plainly throughout the app: the key (and the data flowing through it) is yours, and the relationship is between you and the provider you chose.

Existing configured installs keep their model choices after an OS upgrade. You can add and select Local only in Settings → Models. PCC never silently substitutes for a local-only request, and an unavailable PCC model does not automatically send your request to another provider. Automatic chat titles and empty-chat suggestions do not inherit the PCC default; explicitly selecting PCC for titles does use cloud processing and quota.

---

## What SuperBible DOES do with data

### On your device

Your Bible highlights, notes, reading-plan progress, memorize cards (when that mini-app ships), and chat history are persisted in a local database. Local storage does not mean every AI request is processed locally: the selected model's route above applies. Backups depend on your iOS backup settings.

### When you chat with the AI

Fresh setup selects Local only on iOS 26 and PCC on iOS 27 or later. A configured model may be unavailable because of hardware, setup, connectivity, or usage limits. PCC uses Apple's framework-managed transport, not a SuperBible server or an API key.

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

Parents should review Settings → Models before use. Fresh setup uses Apple's cloud model on iOS 27 or later; choose Local only for on-device model inference. Optional BYOK models process chat content according to their provider's policy. Reading and locally saved study data remain usable without a cloud model.

---

## Changes

If this policy changes, the new version replaces this file in the repository and the "Last updated" date at the top changes. The git history of this file shows every change.

---

## Questions

Open an issue at https://github.com/brianwang9100/Super/issues or email brianwang9100@gmail.com.
