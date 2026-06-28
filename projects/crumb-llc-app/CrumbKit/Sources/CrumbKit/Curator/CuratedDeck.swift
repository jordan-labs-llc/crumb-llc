import Foundation

/// Which curator voice actually produced a deck. The UI uses this to be honest about
/// when the personalized AI curator was unavailable and Crumb fell back to its
/// deterministic offline voice (see ``CuratorTier/ruleBased(_:)``).
public enum CuratorTier: Sendable, Equatable {
    /// Apple's server-tier model (`PrivateCloudComputeLanguageModel`) — best voice,
    /// needs an Apple-Intelligence device, network, and remaining iCloud quota.
    case privateCloud
    /// The on-device model (`SystemLanguageModel.default`) — offline, lower quality.
    case onDevice
    /// The deterministic ``RuleBasedCurator``. `reason == nil` means it was the
    /// configured default (e.g. the mock scaffold) and the UI should stay quiet;
    /// a non-`nil` reason means a real AI tier was *wanted* but unavailable, which the
    /// UI surfaces explicitly.
    case ruleBased(Fallback?)

    /// Why an AI curator tier could not be used, so the UI can phrase an honest note.
    public enum Fallback: Sendable, Equatable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case quotaExhausted
        case offlineOrError
    }
}

public extension CuratorTier {
    /// A short, user-facing note when an AI curator was wanted but unavailable, else `nil`.
    /// Kept in CrumbKit so the voice copy lives next to the seam, not in the views.
    var fallbackNote: String? {
        guard case let .ruleBased(reason?) = self else { return nil }
        switch reason {
        case .deviceNotEligible:
            return "Your personalized curator needs an Apple Intelligence device — "
                + "showing Crumb's standard picks."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to let Crumb curate in its own "
                + "voice. For now, here are the standard picks."
        case .modelNotReady:
            return "Crumb's curator model is still downloading — showing standard picks "
                + "until it's ready."
        case .quotaExhausted:
            return "You've used up this period's private-cloud curation — showing Crumb's "
                + "standard picks for now."
        case .offlineOrError:
            return "Couldn't reach the curator just now — showing Crumb's standard picks."
        }
    }
}

/// The result of a curation pass: the ranked, voice-rewritten products plus the tier that
/// produced them. ``CuratorEngine/curate(_:for:mission:)`` returns this so the app can
/// both deal the deck and, per the fallback reason, be honest about the voice it used.
public struct CuratedDeck: Sendable, Equatable {
    public let products: [Product]
    public let tier: CuratorTier

    public init(products: [Product], tier: CuratorTier) {
        self.products = products
        self.tier = tier
    }
}
