import Testing
import Foundation
@testable import CrumbKit

/// The deterministic kit-completeness read (#67): a partial cart must never pass as a finished kit,
/// a genuine complete package must, and coverage must be by the specific category word — not the
/// shared mission word — so a lacrosse-print accessory can't cover "Lacrosse stick".
@Suite("KitCompleteness")
struct KitCompletenessTests {

    private func product(_ id: String, _ name: String, desc: String = "") -> Product {
        Product(
            id: id, name: name, shop: Shop(id: "s", name: "Shop"), price: 50, rating: 0, reviews: 0,
            rationale: desc, symbol: "bag", gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "\(id).v", title: "Standard", price: 50, checkoutURL: nil)]
        )
    }

    /// The lacrosse kit checklist (the plan the user edited on the Plan screen).
    private let plan = ["Lacrosse stick", "Gloves", "Shoulder pads", "Helmet", "Cleats", "Gear bag"]

    @Test("A cart of only lacrosse sticks covers just the stick part and misses the rest")
    func sticksOnlyIncomplete() {
        let items = [
            product("s1", "STX Stallion 200 Complete Defense Lacrosse Stick"),
            product("s2", "Custom Bravo 1 Elite Lacrosse Stick"),
        ]
        let c = KitCompleteness.assess(plan: plan, items: items)
        #expect(!c.isComplete)
        #expect(c.covered == ["Lacrosse stick"])
        #expect(c.missing == ["Gloves", "Shoulder pads", "Helmet", "Cleats", "Gear bag"])
    }

    @Test("A pet/novelty item sharing only the mission word covers nothing")
    func petAccessoryCoversNothing() {
        // Shares "lacrosse" with the plan but names no head noun (stick/helmet/pads) → covers nothing.
        let items = [product("c1", "Lacrosse Dog Collar", desc: "colorful lacrosse print for your pup")]
        let c = KitCompleteness.assess(plan: plan, items: items)
        #expect(c.covered.isEmpty)
        #expect(c.missing == plan)
    }

    @Test("One item per category completes the kit")
    func fullSetComplete() {
        let items = [
            product("a", "Lacrosse Stick"),
            product("b", "Lacrosse Gloves"),
            product("c", "Shoulder Pads"),
            product("d", "Lacrosse Helmet"),
            product("e", "Turf Cleats"),
            product("f", "Gear Bag"),
        ]
        let c = KitCompleteness.assess(plan: plan, items: items)
        #expect(c.isComplete)
        #expect(c.missing.isEmpty)
        #expect(c.requiredCount == 6)
    }

    @Test("A whole-kit package covers the entire checklist; a 'complete stick' does not")
    func bundleCoversAll() {
        let pkg = KitCompleteness.assess(plan: plan, items: [product("p", "Buffalo Lacrosse Premium Player Package")])
        #expect(pkg.isComplete)   // "package" is a whole-kit signal

        let bundle = KitCompleteness.assess(plan: plan, items: [product("b", "Pre Season Mystery Gear Bundle")])
        #expect(bundle.isComplete)   // "bundle" too

        // "Complete Defense Lacrosse Stick" is a complete *stick*, not a kit — it covers only the stick.
        let stick = KitCompleteness.assess(plan: plan, items: [product("s", "STX Stallion 200 Complete Defense Lacrosse Stick")])
        #expect(!stick.isComplete)
        #expect(stick.covered == ["Lacrosse stick"])
    }

    @Test("An empty kit misses every part; an empty plan requires nothing")
    func emptyEdges() {
        let emptyKit = KitCompleteness.assess(plan: plan, items: [])
        #expect(emptyKit.missing == plan)
        #expect(emptyKit.covered.isEmpty)

        let emptyPlan = KitCompleteness.assess(plan: [], items: [product("a", "Lacrosse Stick")])
        #expect(emptyPlan.requiredCount == 0)
        #expect(emptyPlan.isComplete)   // nothing required → trivially complete
    }
}
