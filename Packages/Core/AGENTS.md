# Core

Shared primitives and brand UI. Read [MOBILE_ARCHITECTURE.md](../../docs/MOBILE_ARCHITECTURE.md) for package boundaries.

- No GRDB dependency. Persistence belongs to applets. Shared SwiftUI brand surfaces are allowed here; applet-domain UI is not.
- `MarkdownText` is the public prose-rendering entry point. Keep its theme builder, linkifier, code blocks, and autocloser internal. Hosts inject `MarkdownBodyMetrics`; preserve the default's parity with Chat's 1.0× appearance (`ChatAppearanceTests`).
- HTTP tests use `URLProtocolStub` with a unique per-test `stubID` and deferred unregister.
- `SuperEventBus.events()` registers synchronously before returning. Tests can subscribe and await the iterator's `next()` without a separate registration delay.
