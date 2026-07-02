import Testing
import Foundation
@testable import Crumb

/// Coverage for the shared AsyncImage cache session (#43 item 1). The "swiping doesn't re-hit the
/// network" behavior is exercised in the simulator, but the cache *configuration* — a real
/// disk+memory `URLCache` and a cache-first policy — is deterministic and pinned here so a silent
/// regression (e.g. the session losing its cache) is caught on CI.
@Suite("CrumbImageCache")
struct CrumbImageCacheTests {

    @Test("The shared image session is backed by a sized disk+memory URLCache with a cache-first policy")
    func sessionIsCacheBacked() {
        let config = CrumbImageCache.session.configuration
        #expect(config.urlCache != nil)
        #expect((config.urlCache?.memoryCapacity ?? 0) >= CrumbImageCache.memoryCapacity)
        #expect((config.urlCache?.diskCapacity ?? 0) >= CrumbImageCache.diskCapacity)
        // Cache-first: an already-cached product photo is served without a network round-trip.
        #expect(config.requestCachePolicy == .returnCacheDataElseLoad)
    }

    @Test("The session is a single shared instance (one cache, not one per view)")
    func sessionIsShared() {
        #expect(CrumbImageCache.session === CrumbImageCache.session)
    }
}
