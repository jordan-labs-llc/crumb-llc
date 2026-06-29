import Foundation
import FoundationModels

/// Composable ``DynamicInstructions`` building blocks shared by every Crumb seam — the dynamic-session
/// replacement for the hand-built persona/taste/mission/refinement instruction *strings* each seam
/// used to interpolate by hand.
///
/// Each block is a small `DynamicInstructions` value driven by runtime state (the taste profile, the
/// mission, an optional gift recipient, an optional live refinement). A seam composes the blocks it
/// needs in a `Profile { … }` and adds its own task-specific guidance leaf:
///
/// ```swift
/// struct CuratorRankInstructions: DynamicInstructions {
///     var body: some DynamicInstructions {
///         CrumbPersona(recipient: recipient)
///         TasteBlock(profile: profile, recipient: recipient, includeBudget: true)
///         MissionBlock(mission: mission)
///         RefinementClause(refinement: refinement)   // emits nothing when not actionable
///         Instructions(Self.rankGuide(recipient: recipient))
///     }
/// }
/// ```
///
/// Every block exposes a pure `static func text(…)` so its content is unit-tested directly (the
/// `body` just wraps that text in an `Instructions` leaf), keeping the CI-safe guarantee even though
/// the model call itself stays untested.

// MARK: - Persona

/// "You are Crumb…" — the shared voice lede, gift-aware. When a `recipient` is set the persona
/// reframes Crumb as the recipient's shopper, so the rest of the instructions read as curating to
/// *their* taste. Used by every seam.
public struct CrumbPersona: DynamicInstructions {
    public let recipient: RecipientRef?

    public init(recipient: RecipientRef?) {
        self.recipient = recipient
    }

    public var body: some DynamicInstructions {
        Instructions(Self.text(recipient: recipient))
    }

    /// The persona sentence(s). Pure — unit-tested.
    public static func text(recipient: RecipientRef?) -> String {
        let base = "You are Crumb, a personal shopping curator with a warm, plainspoken, "
            + "slightly literary voice."
        guard let recipient else { return base }
        let who = recipient.trimmedRelationship.map { "\(recipient.name), \($0)" } ?? recipient.name
        return base + " You are helping someone shop for a gift for \(who) — curate to "
            + "\(recipient.name)'s taste, becoming their shopper."
    }
}

// MARK: - Taste

/// The taste profile as a labeled block: vibe, leanings, optional budget comfort, and the signature
/// line. The label switches to "<Name>'s taste" when shopping for a gift recipient, so the model
/// curates to the right person.
public struct TasteBlock: DynamicInstructions {
    public let profile: TasteProfile
    public let recipient: RecipientRef?
    /// Whether to include the budget-comfort line — the curator ranks with it; the parse/recap
    /// seams omit it.
    public let includeBudget: Bool

    public init(profile: TasteProfile, recipient: RecipientRef?, includeBudget: Bool) {
        self.profile = profile
        self.recipient = recipient
        self.includeBudget = includeBudget
    }

    public var body: some DynamicInstructions {
        Instructions(Self.text(profile: profile, recipient: recipient, includeBudget: includeBudget))
    }

    /// The taste block text. Pure — unit-tested.
    public static func text(profile: TasteProfile, recipient: RecipientRef?, includeBudget: Bool) -> String {
        let owner = recipient.map { "\($0.name)'s taste" } ?? "The user's taste"
        var lines = [
            "\(owner):",
            "- Vibe: \(profile.vibe.joined(separator: ", "))",
            "- Leanings: \(profile.leanings.joined(separator: "; "))",
        ]
        if includeBudget {
            lines.append("- Budget comfort: \(budgetPhrase(profile.budgetComfort))")
        }
        lines.append("- In their words: \"\(profile.signatureLine)\"")
        return lines.joined(separator: "\n")
    }

    /// Maps a 0…1 budget-comfort slider to a short human phrase. Pure — shared by every seam that
    /// voices budget (moved here from the curator so all seams phrase it identically).
    public static func budgetPhrase(_ comfort: Double) -> String {
        switch comfort {
        case ..<0.34: return "thrifty — values getting it right for less"
        case ..<0.67: return "balanced — will pay for quality that lasts"
        default: return "splurge-happy — happy to invest in the best"
        }
    }
}

// MARK: - Mission

/// The current mission — title + subtitle — as a one-line block.
public struct MissionBlock: DynamicInstructions {
    public let mission: ShoppingTask

    public init(mission: ShoppingTask) {
        self.mission = mission
    }

    public var body: some DynamicInstructions {
        Instructions(Self.text(mission: mission))
    }

    /// The mission line. Pure — unit-tested.
    public static func text(mission: ShoppingTask) -> String {
        "The current mission: \"\(mission.title)\" — \(mission.subtitle)"
    }
}

// MARK: - Refinement

/// The user's live refinement (the active directive + the running conversation), as an optional
/// block that **emits nothing** when there's no actionable refinement — so plain curation reads
/// exactly as it did before any refinement. Threaded into ranking and voicing so the model honors
/// "make it cheaper / warmer / drop the synthetic" holistically.
public struct RefinementClause: DynamicInstructions {
    public let refinement: RefinementContext?

    public init(refinement: RefinementContext?) {
        self.refinement = refinement
    }

    public var body: some DynamicInstructions {
        if let text = Self.text(refinement: refinement) {
            Instructions(text)
        }
    }

    /// The refinement block text, or `nil` when there's nothing actionable to honor (the block then
    /// emits nothing). Pure — unit-tested.
    public static func text(refinement: RefinementContext?) -> String? {
        guard let refinement,
              refinement.directive.isActionable || !refinement.conversation.isEmpty
        else { return nil }
        var lines = ["The user is refining this deck. Honor what they asked:"]
        let directive = refinement.directive
        if !directive.emphasis.isEmpty { lines.append("- Emphasis: \(directive.emphasis)") }
        switch directive.priceDirection {
        case .cheaper: lines.append("- Price: prefer cheaper options.")
        case .pricier: lines.append("- Price: they're happy to spend more for better.")
        case .none: break
        }
        if !directive.removeHints.isEmpty {
            lines.append("- Avoid / de-emphasize: \(directive.removeHints.joined(separator: ", ")).")
        }
        if refinement.conversation.count > 1 {
            let earlier = refinement.conversation.dropLast().joined(separator: "; ")
            lines.append("- Earlier refinements still apply: \(earlier).")
        }
        return lines.joined(separator: "\n")
    }
}
