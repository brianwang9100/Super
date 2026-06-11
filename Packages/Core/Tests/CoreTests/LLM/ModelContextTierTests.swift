import Testing
@testable import Core

/// Verifies the context-window classification that drives compact-vs-full
/// prompt assembly: on-device windows fall in `.compact`, every cloud/BYOK
/// window in `.full`.
@Suite("ModelContextTier")
struct ModelContextTierTests {
    @Test("on-device windows (4096, 8192) classify as compact")
    func onDeviceIsCompact() {
        #expect(ModelContextTier(maxContextTokens: 4_096) == .compact)
        #expect(ModelContextTier(maxContextTokens: 8_192) == .compact)
    }

    @Test("the ceiling is inclusive; one token over is full")
    func ceilingBoundary() {
        #expect(ModelContextTier(maxContextTokens: ModelContextTier.compactCeiling) == .compact)
        #expect(ModelContextTier(maxContextTokens: ModelContextTier.compactCeiling + 1) == .full)
    }

    @Test("cloud/BYOK windows (32K, 200K, 1M) classify as full")
    func cloudIsFull() {
        #expect(ModelContextTier(maxContextTokens: 32_768) == .full)
        #expect(ModelContextTier(maxContextTokens: 200_000) == .full)
        #expect(ModelContextTier(maxContextTokens: 1_000_000) == .full)
    }
}
