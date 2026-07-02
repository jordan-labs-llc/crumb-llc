import Testing
import Foundation
@testable import CrumbKit

/// The pure text behind each seam's dynamic-session instruction struct (PR 2). The `body` of each
/// struct composes the shared blocks (covered in `CrumbInstructionBlocksTests`) plus these
/// seam-specific guide/role leaves; testing the `text`/`guide`/`context` helpers verifies the
/// instruction content the model receives — the CI-safe guarantee behind the (untested) model call.
@Suite("Seam instructions (PR2)")
struct SeamInstructionsTests {

    private func recipient(_ name: String, _ relationship: String? = nil) -> RecipientRef {
        RecipientRef(id: "r.\(name)", name: name, relationship: relationship, accentHex: 0x1C4B43)
    }

    // MARK: Planner

    @Test("Planner guide asks for an altitude-matched plan (single item vs up-to-N) and the decline")
    func plannerGuide() {
        let guide = PlannerInstructions.guide
        #expect(guide.contains("up to \(RuleBasedMissionPlanner.maxParts)"))   // broad-goal ceiling, not a floor
        #expect(guide.contains("isSingleItem to true"))                        // the single-item altitude
        #expect(guide.contains("never pad"))                                    // no accessory padding
        #expect(guide.contains("set isShoppable to false"))
        // #65: a gear/equipment goal is a complete kit, not a single generic part like "collar".
        #expect(guide.contains("complete multi-part kit"))
        #expect(guide.contains("collar"))                                       // the anti-example
    }

    // MARK: Relevance gate

    @Test("Gate guide asks for only the clearly off-topic IDs, empty when all on-topic")
    func gateGuide() {
        let guide = GateInstructions.guide
        #expect(guide.contains("clearly off-topic"))
        #expect(guide.contains("return an empty list"))
    }

    // MARK: Refinement interpreter

    @Test("Refiner guide enumerates the structured directive fields")
    func refinerGuide() {
        let guide = RefinerInstructions.guide
        #expect(guide.contains("emphasis:"))
        #expect(guide.contains("priceDirection:"))
        #expect(guide.contains("addQueries:"))
        #expect(guide.contains("removeHints:"))
    }

    // MARK: Taste extractor

    @Test("Extractor text asks for a faithful structured distillation")
    func extractorText() {
        let text = ExtractorInstructions.text
        #expect(text.contains("distill it into a"))
        #expect(text.contains("structured profile"))
        #expect(text.contains("budget comfort"))
    }

    // MARK: Recap writer

    @Test("Recap context frames a personal memory, or a gift memory naming the recipient")
    func recapContext() {
        #expect(RecapInstructions.context(recipient: nil).contains("kit a person just put together"))
        let gift = RecapInstructions.context(recipient: recipient("Maya", "your sister"))
        #expect(gift.contains("gift kit someone just assembled for Maya, your sister"))
    }

    @Test("Recap write guide asks for a tag + line, gift-aware")
    func recapWriteGuide() {
        let plain = RecapInstructions.writeGuide(recipient: nil)
        #expect(plain.contains("2 to 4 word tag"))
        #expect(plain.contains("captures the feeling of the kit"))
        let gift = RecapInstructions.writeGuide(recipient: recipient("Maya"))
        #expect(gift.contains("acknowledge it's for Maya"))
    }
}
