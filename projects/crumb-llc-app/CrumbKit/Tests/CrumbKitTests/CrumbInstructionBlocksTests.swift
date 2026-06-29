import Testing
import Foundation
@testable import CrumbKit

/// The pure text behind the composable ``DynamicInstructions`` blocks. The `body` of each block just
/// wraps these strings in an `Instructions` leaf, so testing the `text(…)` helpers verifies the
/// instruction content the model receives — the CI-safe guarantee behind the (untested) model call.
@Suite("Crumb instruction blocks")
struct CrumbInstructionBlocksTests {

    // MARK: Fixtures

    private let taste = TasteProfile(
        vibe: ["Quiet", "Earthy"],
        leanings: ["Merino over synthetic", "Muted tones"],
        budgetComfort: 0.5,
        signatureLine: "Buy once, cry once."
    )

    private func recipient(_ name: String, _ relationship: String? = nil) -> RecipientRef {
        RecipientRef(id: "r.\(name)", name: name, relationship: relationship, accentHex: 0x1C4B43)
    }

    private let mission = ShoppingTask(
        id: "goal.pourover",
        title: "Pour-over corner",
        subtitle: "Slower mornings · better cup",
        plan: ["Kettle", "Grinder"],
        curatorNote: "",
        accentHex: 0x1C4B43,
        candidateIDs: [],
        searchQueries: ["gooseneck kettle", "burr grinder"]
    )

    // MARK: Persona

    @Test("Persona without a recipient is the plain Crumb voice — no gift clause")
    func personaPlain() {
        let text = CrumbPersona.text(recipient: nil)
        #expect(text.contains("You are Crumb, a personal shopping curator"))
        #expect(!text.contains("gift"))
    }

    @Test("Persona with a recipient names them and reframes Crumb as their shopper")
    func personaGift() {
        let text = CrumbPersona.text(recipient: recipient("Maya"))
        #expect(text.contains("a gift for Maya"))
        #expect(text.contains("Maya's taste, becoming their shopper"))
    }

    @Test("Persona folds in the recipient's relationship when present")
    func personaGiftRelationship() {
        let text = CrumbPersona.text(recipient: recipient("Maya", "your sister"))
        #expect(text.contains("a gift for Maya, your sister"))
    }

    // MARK: Taste

    @Test("Taste block labels the owner — the user by default, the recipient for a gift")
    func tasteOwnerLabel() {
        #expect(TasteBlock.text(profile: taste, recipient: nil, includeBudget: true).contains("The user's taste:"))
        #expect(TasteBlock.text(profile: taste, recipient: recipient("Maya"), includeBudget: true).contains("Maya's taste:"))
    }

    @Test("Taste block joins vibe and leanings and quotes the signature line")
    func tasteContent() {
        let text = TasteBlock.text(profile: taste, recipient: nil, includeBudget: true)
        #expect(text.contains("Vibe: Quiet, Earthy"))
        #expect(text.contains("Leanings: Merino over synthetic; Muted tones"))
        #expect(text.contains("\"Buy once, cry once.\""))
    }

    @Test("Budget line is present only when requested")
    func tasteBudgetToggle() {
        #expect(TasteBlock.text(profile: taste, recipient: nil, includeBudget: true).contains("Budget comfort:"))
        #expect(!TasteBlock.text(profile: taste, recipient: nil, includeBudget: false).contains("Budget comfort:"))
    }

    @Test("Budget phrase maps the slider to thrifty / balanced / splurge bands")
    func budgetPhrase() {
        #expect(TasteBlock.budgetPhrase(0.1).contains("thrifty"))
        #expect(TasteBlock.budgetPhrase(0.5).contains("balanced"))
        #expect(TasteBlock.budgetPhrase(0.9).contains("splurge"))
    }

    // MARK: Mission

    @Test("Mission block renders the title and subtitle")
    func missionLine() {
        #expect(MissionBlock.text(mission: mission) == "The current mission: \"Pour-over corner\" — Slower mornings · better cup")
    }

    // MARK: Refinement

    @Test("Refinement block emits nothing when there is nothing actionable")
    func refinementNoop() {
        #expect(RefinementClause.text(refinement: nil) == nil)
        let empty = RefinementContext(directive: RefinementDirective(), conversation: [])
        #expect(RefinementClause.text(refinement: empty) == nil)
    }

    @Test("Refinement block surfaces emphasis, price lean, removals, and earlier turns")
    func refinementContent() {
        let directive = RefinementDirective(
            emphasis: "warmer tones",
            addQueries: [],
            priceDirection: .cheaper,
            removeHints: ["synthetic"]
        )
        let context = RefinementContext(directive: directive, conversation: ["make it warmer", "and cheaper"])
        let text = RefinementClause.text(refinement: context)
        #expect(text != nil)
        let body = try! #require(text)
        #expect(body.contains("- Emphasis: warmer tones"))
        #expect(body.contains("- Price: prefer cheaper options."))
        #expect(body.contains("- Avoid / de-emphasize: synthetic."))
        #expect(body.contains("Earlier refinements still apply: make it warmer"))
    }

    @Test("Pricier lean phrases the spend-up willingness")
    func refinementPricier() {
        let directive = RefinementDirective(priceDirection: .pricier)
        let context = RefinementContext(directive: directive, conversation: [])
        let body = try! #require(RefinementClause.text(refinement: context))
        #expect(body.contains("happy to spend more"))
    }

    // MARK: Curator guides (the seam-specific leaves)

    @Test("Rank guide addresses the user, or the gift recipient by name")
    func rankGuide() {
        #expect(CuratorRankInstructions.rankGuide(recipient: nil).contains("THIS user"))
        #expect(CuratorRankInstructions.rankGuide(recipient: recipient("Maya")).contains("Maya (the gift's recipient)"))
    }

    @Test("Voice guide frames the note as a gift when shopping for someone")
    func voiceGuide() {
        #expect(CuratorVoiceInstructions.voiceGuide(recipient: nil).contains("speaks to \"you\""))
        let gift = CuratorVoiceInstructions.voiceGuide(recipient: recipient("Maya"))
        #expect(gift.contains("frames the product as a gift for Maya"))
    }
}
