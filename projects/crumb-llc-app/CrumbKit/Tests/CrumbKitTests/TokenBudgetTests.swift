import Testing
@testable import CrumbKit

/// Pure, CI-safe coverage for the queried token budget (#37). No model calls: the derivations are
/// exercised through explicit window sizes and a deterministic ``ContextWindowProviding`` double, so
/// the guarantee — "reproduce the hand-tuned constants at 4096, scale up (capped) on a bigger
/// window" — is locked without touching FoundationModels.
@Suite("TokenBudget")
struct TokenBudgetTests {

    /// A stand-in model that reports whatever window the test wants.
    private struct FakeModel: ContextWindowProviding {
        let contextWindow: Int
    }

    @Test("At the 4096 baseline every derived cap equals its historical hand-tuned constant")
    func baselineReproducesLegacyConstants() {
        let b = TokenBudget(contextWindow: 4096)
        #expect(b.rankDeckCap == 25)
        #expect(b.rankChunkSize == 6)
        #expect(b.rankAdvancePerChunk == 2)
        #expect(b.rankMaxResponseTokens == 512)
        #expect(b.voiceMaxResponseTokens == 200)
        #expect(b.plannerMaxResponseTokens == 1024)
    }

    @Test("A larger window ranks bigger chunks, so a full deck needs fewer model calls (#37)")
    func largerWindowScalesUpAndCutsCalls() {
        let base = TokenBudget(contextWindow: 4096)
        let big = TokenBudget(contextWindow: 8192)

        // Caps grow with the window.
        #expect(big.rankChunkSize > base.rankChunkSize)
        #expect(big.rankDeckCap >= base.rankDeckCap)
        #expect(big.rankMaxResponseTokens >= base.rankMaxResponseTokens)
        #expect(big.plannerMaxResponseTokens >= base.plannerMaxResponseTokens)

        // Concretely: an 8192 window ranks a 25-card deck in fewer chunks than 4096 did.
        func chunkCount(deck: Int, chunk: Int) -> Int { (deck + chunk - 1) / chunk }
        let baseCalls = chunkCount(deck: base.rankDeckCap, chunk: base.rankChunkSize)
        let bigCalls = chunkCount(deck: 25, chunk: big.rankChunkSize)
        #expect(bigCalls < baseCalls)
    }

    @Test("advance-per-chunk stays a strictly-converging guard, independent of window")
    func advanceStaysConverging() {
        for window in [4096, 8192, 16384, 100_000] {
            let b = TokenBudget(contextWindow: window)
            #expect(b.rankAdvancePerChunk >= 1)
            #expect(b.rankAdvancePerChunk < b.rankChunkSize, "advance must stay below chunk size so the tournament converges")
        }
    }

    @Test("Caps are bounded so an enormous window can't blow up deck size or response length")
    func capsAreBounded() {
        let huge = TokenBudget(contextWindow: 1_000_000)
        #expect(huge.rankChunkSize <= 12)
        #expect(huge.rankDeckCap <= 60)
        #expect(huge.rankMaxResponseTokens <= 1024)
        #expect(huge.voiceMaxResponseTokens <= 400)
        #expect(huge.plannerMaxResponseTokens <= 2048)
    }

    @Test("A not-ready model reporting an absurd window floors at the documented fallback")
    func absurdWindowFloorsToFallback() {
        // 0 / tiny → treated as the 4096 fallback, so caps never shrink below today's baseline.
        #expect(TokenBudget(contextWindow: 0) == TokenBudget(contextWindow: 4096))
        #expect(TokenBudget(contextWindow: 100).rankChunkSize == 6)
        #expect(TokenBudget(contextWindow: -5).contextWindow == TokenBudget.fallbackContextWindow)
    }

    @Test("init(model:) reads the window off a ContextWindowProviding model")
    func readsWindowOffModel() {
        #expect(TokenBudget(model: FakeModel(contextWindow: 8192)) == TokenBudget(contextWindow: 8192))
        #expect(TokenBudget(model: FakeModel(contextWindow: 4096)).rankChunkSize == 6)
    }
}
