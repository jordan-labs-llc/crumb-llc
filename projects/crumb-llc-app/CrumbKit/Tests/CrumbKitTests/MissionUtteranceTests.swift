import Testing
import Foundation
@testable import CrumbKit

/// Pins the contract for reading a typed message as intent.
///
/// The suite leads with the verbatim session that prompted this work, because it is the case the
/// old parser got wrong in the most expensive way: it answered a decision with a re-curation.
@Suite("Mission utterance")
struct MissionUtteranceTests {

    // MARK: The reported failure

    @Test("\"I like it. Let's create a cart.\" keeps the pick and asks for the cart")
    func reportedFailure() {
        // Verbatim, including the curly apostrophe iOS smart quotes actually produce.
        let utterance = MissionUtterance.parse("I like it. Let\u{2019}s create a cart.")
        #expect(utterance.decision == .add)
        #expect(utterance.nextStep == .reviewCart)
        #expect(utterance.refinement == nil)
        // The specific regression: this must never be read as "change the picks".
        #expect(!utterance.isPureRefinement)
    }

    @Test("A straight apostrophe reads the same as a curly one")
    func apostropheFolding() {
        #expect(MissionUtterance.parse("I like it. Let's create a cart.")
            == MissionUtterance.parse("I like it. Let\u{2019}s create a cart."))
    }

    // MARK: Decisions

    @Test("Plain assent adds", arguments: [
        "add it", "keep it", "yes", "yep", "sure", "I like it", "Looks good", "that works",
        "OK add it please", "Perfect!",
    ])
    func assentAdds(_ text: String) {
        #expect(MissionUtterance.parse(text).decision == .add)
    }

    @Test("Plain refusal skips", arguments: [
        "skip", "no thanks", "pass", "not for me", "I don't like it", "nope", "drop it",
    ])
    func refusalSkips(_ text: String) {
        #expect(MissionUtterance.parse(text).decision == .skip)
    }

    /// The single most dangerous failure mode. A substring matcher sees "like it" inside
    /// "I don't like it" and adds the thing the person just rejected.
    @Test("A negation is never read as the assent it contains")
    func negationIsNotAssent() {
        for text in ["I don't like it", "I dont like it", "not this one", "no thanks"] {
            #expect(MissionUtterance.parse(text).decision != .add, "\(text) must not add")
        }
    }

    @Test("An unlisted sentence stays a change request")
    func unknownIsRefinement() {
        let utterance = MissionUtterance.parse("something less floral and under $25")
        #expect(utterance.isPureRefinement)
        #expect(utterance.refinement == "something less floral and under $25")
        #expect(utterance.decision == nil)
    }

    @Test("Ordinals never resolve to a write")
    func ordinalsNeverResolve() {
        for text in ["add the second one", "the first one", "take number three"] {
            #expect(MissionUtterance.parse(text).decision == nil, "\(text) must not decide")
        }
    }

    // MARK: Next steps

    @Test("Cart phrasing asks to look, not to pay", arguments: [
        "let's create a cart", "make me a cart", "show me the cart", "review cart",
    ])
    func cartIsReview(_ text: String) {
        #expect(MissionUtterance.parse(text).nextStep == .reviewCart)
    }

    @Test("Checkout phrasing asks to pay", arguments: [
        "check out", "place the order", "pay now", "I'm ready to buy",
    ])
    func checkoutIsCheckout(_ text: String) {
        #expect(MissionUtterance.parse(text).nextStep == .checkout)
    }

    @Test("\"Buy it\" is both a yes and an instruction to pay")
    func buyItIsCompound() {
        let utterance = MissionUtterance.parse("buy it")
        #expect(utterance.decision == .add)
        #expect(utterance.nextStep == .checkout)
    }

    @Test("Paying outranks looking when a message asks for both")
    func checkoutOutranksReview() {
        #expect(MissionUtterance.parse("show me the cart and check out").nextStep == .checkout)
    }

    // MARK: Clause handling

    @Test("A conjunction splits only when every piece is understood")
    func conjunctionSplitsOnlyWhenItResolves() {
        // Both pieces are vocabulary, so the split is used.
        let resolved = MissionUtterance.parse("no thanks, show me another")
        #expect(resolved.decision == .showAnother)

        // "make it black" and "green" are not, so the sentence survives whole and unmangled —
        // this is the case that a naive split turns into "make it black. green".
        let unresolved = MissionUtterance.parse("make it black and green")
        #expect(unresolved.isPureRefinement)
        #expect(unresolved.refinement == "make it black and green")
    }

    @Test("A decision keeps the leftover clause as a change request, in the person's own words")
    func decisionCarriesLeftover() {
        let utterance = MissionUtterance.parse("I like it. But find something cheaper.")
        #expect(utterance.decision == .add)
        #expect(utterance.refinement == "But find something cheaper")
    }

    @Test("Opposite decisions in one message decide nothing")
    func contradictionRefusesToGuess() {
        let utterance = MissionUtterance.parse("add it. actually skip it.")
        #expect(utterance.decision == nil)
        #expect(utterance.isPureRefinement)
    }

    @Test("Skip and show-another are the same rejection, and reconcile")
    func compatibleDecisionsReconcile() {
        #expect(MissionUtterance.parse("not this one. show me another.").decision == .showAnother)
    }

    // MARK: Invariants

    /// ``MissionUtterance/shedPadding(_:)`` is only safe because no padding word is itself a
    /// vocabulary entry — otherwise shedding could turn one recognised phrase into a different one.
    @Test("No padding word is a vocabulary entry")
    func paddingNeverCarriesIntent() {
        for word in ["ok", "okay", "oh", "alright", "well", "so", "hmm", "um", "uh",
                     "actually", "i think", "i guess", "lets", "let's", "please",
                     "thanks", "thank you", "for me", "though"] {
            #expect(MissionUtterance.parse(word).isPureRefinement, "\(word) must carry no intent")
        }
    }

    @Test("Empty and whitespace input decide nothing and refine nothing")
    func emptyIsInert() {
        for text in ["", "   ", "\n\n"] {
            let utterance = MissionUtterance.parse(text)
            #expect(utterance.decision == nil)
            #expect(utterance.nextStep == nil)
            #expect(utterance.refinement == nil)
        }
    }

    @Test("Parsing is deterministic")
    func deterministic() {
        let text = "I like it. Let\u{2019}s create a cart."
        #expect(MissionUtterance.parse(text) == MissionUtterance.parse(text))
    }
}
