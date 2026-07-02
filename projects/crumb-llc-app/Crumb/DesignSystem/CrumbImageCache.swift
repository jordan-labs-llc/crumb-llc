import Foundation

/// A shared, disk-backed image-loading session for `AsyncImage` (#43 item 1).
///
/// iOS 26 `AsyncImage` refetched a photo on every appearance, so swiping the deck back and forth —
/// and re-showing kit-tray / cart thumbnails — re-downloaded the same product images every time.
/// iOS 27 `AsyncImage` loads through a caller-supplied `URLSession` via `.asyncImageURLSession(_:)`;
/// wiring this one cache-backed session at the app root (see `RootView`) means an already-seen
/// image is served from the `URLCache` instead of the network.
///
/// Product-photo URLs are effectively immutable (a changed photo ships under a new URL), so the
/// session uses `.returnCacheDataElseLoad`: once an image is cached it is reused without a network
/// round-trip, even when a CDN sends conservative cache headers — which is exactly the deck-swipe
/// win the issue asks for, with no staleness risk for content-addressed assets.
enum CrumbImageCache {

    /// Memory budget for decoded/encoded image responses held hot.
    static let memoryCapacity = 32 * 1024 * 1024      // 32 MB
    /// On-disk budget so cached photos survive relaunch and memory pressure.
    static let diskCapacity = 256 * 1024 * 1024       // 256 MB

    /// The `URLSession` whose `URLCache` backs every `AsyncImage` load app-wide.
    static let session: URLSession = {
        let cache = URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, directory: nil)
        let config = URLSessionConfiguration.default
        config.urlCache = cache
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()
}
