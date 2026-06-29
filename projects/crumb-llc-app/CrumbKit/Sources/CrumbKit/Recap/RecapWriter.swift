import Foundation

/// The recap-writing seam: turns a finished mission — the goal, the plan, the **kept** items, and
/// the user's taste — into a short, warm record line in Crumb's voice, plus a 2–4 word tag used as
/// the saved kit's crafted title ("Rainy-hike kit").
///
/// This is the fourth on-device twin of ``CuratorEngine`` / ``MissionPlanner`` /
/// ``RefinementInterpreter`` / ``TasteExtractor``: the deterministic ``RuleBasedRecapWriter`` is the
/// offline floor (and the only writer that runs on the sim/CI, where the on-device model is
/// unavailable), and ``AppleFoundationRecapWriter`` is the on-device writer that actually *composes*
/// the recap. Both report the ``RecapTier`` they ran on, so the same honest-fallback story holds —
/// though History stays quiet about it (the recap line itself is the artifact; the tier note is
/// only meaningful when an AI tier was wanted, which on a real device degrades gracefully).
public protocol RecapWriter: Sendable {
    /// Writes a recap for a kept kit. Never throws: an unusable model tier degrades to the
    /// deterministic floor, which always returns a clean tag + line.
    ///
    /// When `recipient` is set the kit is a **gift** for that person, and the recap acknowledges it
    /// by name ("a gift for Mom"). `recipient == nil` is a kit for the owner — today's behavior.
    func writeRecap(
        goal: String,
        plan: [String],
        items: [RecapFact],
        profile: TasteProfile,
        recipient: RecipientRef?
    ) async -> WrittenRecap
}

public extension RecapWriter {
    /// Back-compat / owner-kit entry point — a recap with no gift recipient.
    func writeRecap(
        goal: String,
        plan: [String],
        items: [RecapFact],
        profile: TasteProfile
    ) async -> WrittenRecap {
        await writeRecap(goal: goal, plan: plan, items: items, profile: profile, recipient: nil)
    }
}

/// The minimal fact about one kept item the recap leans on — name, shop, price. A lean projection
/// of ``HistoryItem`` so the writer never sees (or needs) the whole snapshot.
public struct RecapFact: Sendable, Equatable {
    public let name: String
    public let shop: String
    public let price: Decimal

    public init(name: String, shop: String, price: Decimal) {
        self.name = name
        self.shop = shop
        self.price = price
    }

    /// Projects a saved ``HistoryItem`` to the facts the recap needs.
    public init(_ item: HistoryItem) {
        self.init(name: item.name, shop: item.shop.name, price: item.price)
    }
}

/// The result of a recap pass: the crafted `tag` (card title) and curator-voice `line`, plus the
/// ``RecapTier`` that produced them so the path tells the same honest story as the other seams.
public struct WrittenRecap: Sendable, Equatable {
    /// A short 2–4 word kit title ("Rainy-hike kit").
    public let tag: String
    /// One warm record line in Crumb's voice ("quiet, waterproof, built to last").
    public let line: String
    /// Which writer tier produced this.
    public let tier: RecapTier

    public init(tag: String, line: String, tier: RecapTier) {
        self.tag = tag
        self.line = line
        self.tier = tier
    }
}

/// Which writer produced a recap. Mirrors ``CuratorTier`` / ``PlannerTier`` / ``RefinementTier``:
/// `ruleBased(nil)` is the *chosen* offline default (quiet), while `ruleBased(reason)` means an AI
/// tier was wanted but unavailable.
public enum RecapTier: Sendable, Equatable {
    /// Apple's server-tier model (`PrivateCloudComputeLanguageModel`, OS 27+).
    case privateCloud
    /// The on-device model (`SystemLanguageModel.default`) — offline, lower quality.
    case onDevice
    /// The deterministic ``RuleBasedRecapWriter``. `reason == nil` means it was the chosen default
    /// (the mock scaffold / sim); a non-`nil` reason means an AI tier was *wanted* but unavailable.
    case ruleBased(Fallback?)

    /// Why an AI writer tier could not be used, so the UI *could* phrase an honest note.
    public enum Fallback: Sendable, Equatable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case quotaExhausted
        case offlineOrError
    }
}

public extension RecapTier {
    /// A short, user-facing note when an AI writer was wanted but unavailable, else `nil`. Kept in
    /// CrumbKit so the voice copy lives next to the seam. History generally stays quiet (the recap
    /// line is the artifact), but the note is available for parity with the other seams.
    var fallbackNote: String? {
        guard case let .ruleBased(reason?) = self else { return nil }
        switch reason {
        case .deviceNotEligible:
            return "A warmer recap needs an Apple Intelligence device — I wrote a simple one."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence to let me write a warmer recap. For now, a simple one."
        case .modelNotReady:
            return "My recap model is still downloading — a simple recap for now."
        case .quotaExhausted:
            return "You've used up this period's private-cloud writing — a simple recap for now."
        case .offlineOrError:
            return "Couldn't reach the writer just now — a simple recap from your kit."
        }
    }
}
