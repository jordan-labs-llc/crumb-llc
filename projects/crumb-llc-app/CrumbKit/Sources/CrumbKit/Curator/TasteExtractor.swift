import Foundation

/// Turns a free-text "describe your taste" sentence into a structured ``TasteProfile``.
///
/// This is the AI accelerator for taste capture: the user can type "quiet earthy gear,
/// merino over synthetic, I'd rather own a few things I love" and have Crumb fill in the
/// vibe / leaning chips, budget, and signature line — which they can then hand-tune. It is a
/// seam (like ``CuratorEngine``) so the deterministic manual path never depends on a model.
///
/// Returning `nil` means "no parse" — no model tier was usable, or the model gave nothing
/// usable — and the caller keeps whatever the user has set by hand. So extraction can only
/// ever *help*; it never blanks a field. (That `nil` is the whole reason this is a seam:
/// ``ManualTasteExtractor`` returns `nil` unconditionally, keeping onboarding tests free of
/// the model.)
public protocol TasteExtractor: Sendable {
    /// Parses `text` into a profile, using `base` for any field the description doesn't
    /// cover (so a partial sentence tops up the defaults instead of erasing them). Returns
    /// `nil` when no model tier is available or the parse yields nothing usable.
    func extract(from text: String, base: TasteProfile) async -> TasteProfile?
}

/// The always-manual extractor: never parses, always returns `nil`. The keyless default
/// (paired with ``MockUCPClient``) and the one tests use so taste capture stays
/// deterministic — onboarding falls back to the chips/slider with no model in the loop.
public struct ManualTasteExtractor: TasteExtractor {
    public init() {}
    public func extract(from text: String, base: TasteProfile) async -> TasteProfile? { nil }
}
