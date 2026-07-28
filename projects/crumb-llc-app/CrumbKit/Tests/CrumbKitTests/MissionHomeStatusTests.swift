import Testing
import Foundation
@testable import CrumbKit

/// Home's three-state reading of a mission, and the coarse stamp that finally makes its sort visible.
@Suite("MissionHomeStatus")
struct MissionHomeStatusTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static let taste = TasteProfile(
        vibe: ["calm"], leanings: ["durable"], budgetComfort: 0.4,
        signatureLine: "quietly useful"
    )
    /// A fixed calendar/locale so bucket boundaries don't move with the machine running the suite.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func thread(_ phase: MissionThreadPhase) -> MissionThread {
        var thread = MissionThread(goal: "Find premium jasmine tea", taste: Self.taste, now: Self.now)
        thread.phase = phase
        return thread
    }

    private func product(_ id: String, price: Decimal) -> Product {
        Product(
            id: id, name: "Tea \(id)", shop: SeedData.Shops.millOak, price: price,
            rating: 4.5, reviews: 12, rationale: "test fixture", symbol: "leaf",
            gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "\(id)-v", title: "Default", price: price)]
        )
    }

    private func relative(_ secondsAgo: TimeInterval) -> String {
        MissionHomeStatus.relativeTime(
            Self.now.addingTimeInterval(-secondsAgo),
            now: Self.now,
            calendar: Self.calendar,
            locale: Locale(identifier: "en_US")
        )
    }

    // MARK: State

    @Test("Crumb's own work is 'working', not something waiting on the person")
    func inFlightPhasesAreWorking() {
        #expect(MissionHomeStatus.state(for: thread(.planning)) == .working)
        #expect(MissionHomeStatus.state(for: thread(.gathering)) == .working)
    }

    @Test("A settled gather holding nothing is a stall, not a finished mission")
    func emptySettledDeckIsAStall() {
        // This is the distinction Home could not previously draw: `deckReady` is a state-machine
        // fact, so an empty deck rendered as the same kind of row as a full one.
        let settled = thread(.deckReady)
        #expect(settled.kit.isEmpty)
        #expect(MissionHomeStatus.state(for: settled) == .stalled)
        #expect(MissionHomeStatus.detail(for: settled) == "Nothing found yet")
    }

    @Test("A deck with kept items or unreviewed picks is ready")
    func populatedDeckIsReady() {
        var kept = thread(.deckReady)
        kept.kit = [KitItem(product: product("p1", price: 42))]
        #expect(MissionHomeStatus.state(for: kept) == .ready)

        var unreviewed = thread(.deckReady)
        unreviewed.candidates = [product("p2", price: 12)]
        unreviewed.remainingDeckIDs = unreviewed.candidates.map(\.id)
        #expect(MissionHomeStatus.state(for: unreviewed) == .ready)
    }

    @Test("A failed mission is stalled and states its own reason instead of 'Needs attention'")
    func failureCarriesItsReason() {
        var failed = thread(.failed)
        failed.appendEvent(
            kind: .failure,
            text: "I couldn't reach the shops. You can retry when you're ready.",
            createdAt: Self.now
        )
        #expect(MissionHomeStatus.state(for: failed) == .stalled)
        #expect(MissionHomeStatus.detail(for: failed).hasPrefix("I couldn't reach the shops"))
    }

    @Test("A failure with no recorded sentence still says something honest")
    func failureWithoutAnEventFallsBack() {
        let bare = thread(.failed)
        #expect(MissionHomeStatus.detail(for: bare) == "Stopped before it finished")
    }

    // MARK: The live work counter

    @Test("A search that has found things says how many, in the header and on Home")
    func gatheringReportsItsFindCount() {
        var searching = thread(.gathering)
        searching.task = SeedData.coffee
        searching.candidates = (1...24).map { product("p\($0)", price: 12) }
        #expect(MissionHomeStatus.workingDetail(for: searching) == "Found 24 so far")
        #expect(MissionHomeStatus.detail(for: searching) == "Found 24 so far")
    }

    @Test("A search with nothing yet stays quiet rather than saying 'Found 0'")
    func emptyGatherHasNothingToReport() {
        var searching = thread(.gathering)
        searching.task = SeedData.coffee
        #expect(MissionHomeStatus.workingDetail(for: searching) == nil)
        // The pill beside the spinner is already saying this much; a zero would be a third copy.
        #expect(MissionHomeStatus.detail(for: searching) == MissionContinuationSummary.text(for: searching))
    }

    @Test("Planning never claims a find count — it has issued no search at all")
    func planningIsNotSearching() {
        // `.planning` and `.gathering` are both `.working` state, so this is the fabrication the
        // counter has to be narrow enough to avoid.
        var planning = thread(.planning)
        planning.candidates = [product("stale", price: 9)]
        #expect(MissionHomeStatus.workingDetail(for: planning) == nil)
        #expect(MissionHomeStatus.detail(for: planning) == "Planning")
    }

    @Test("A settled deck goes back to reporting its contents, not its search")
    func settledDeckDropsTheCounter() {
        var settled = thread(.deckReady)
        settled.candidates = (1...24).map { product("p\($0)", price: 12) }
        settled.remainingDeckIDs = settled.candidates.map(\.id)
        #expect(MissionHomeStatus.workingDetail(for: settled) == nil)
        #expect(MissionHomeStatus.detail(for: settled) != "Found 24 so far")
    }

    @Test("Every phase maps to a state, so a new phase is a compile error and not a silent default")
    func mappingIsTotal() {
        for phase in MissionThreadPhase.allCases {
            _ = MissionHomeStatus.state(for: thread(phase))
        }
    }

    // MARK: Relative time

    @Test("Under a minute reads as 'Just now', and a future stamp never reads as negative")
    func subMinuteAndSkew() {
        #expect(relative(0) == "Just now")
        #expect(relative(45) == "Just now")
        #expect(relative(-600) == "Just now")
    }

    @Test("Minutes and hours are counted; the boundary at an hour flips cleanly")
    func minutesThenHours() {
        #expect(relative(60) == "1m ago")
        #expect(relative(18 * 60) == "18m ago")
        #expect(relative(59 * 60) == "59m ago")
        #expect(relative(3600) == "1h ago")
        #expect(relative(5 * 3600) == "5h ago")
    }

    @Test("Yesterday is named, not counted — and hours only apply within the same calendar day")
    func yesterdayIsNamed() {
        // `now` is 2023-11-14 22:13 UTC. 20h back is still the same calendar day, so the hour count
        // is the honest reading; 30h back crosses midnight and must be named instead of counted.
        #expect(relative(20 * 3600) == "20h ago")
        #expect(relative(30 * 3600) == "Yesterday")
        // The boundary case that would otherwise read "23h ago" on a different day.
        #expect(relative(23 * 3600) == "Yesterday")
    }

    @Test("Days, then 'Last week', then an absolute date rather than counting to 37d")
    func coarseBucketsHandOffToADate() {
        #expect(relative(3 * 86_400) == "3d ago")
        #expect(relative(6 * 86_400) == "6d ago")
        #expect(relative(8 * 86_400) == "Last week")
        #expect(relative(13 * 86_400) == "Last week")
        // Past a fortnight the count stops being useful, so it becomes a date.
        let old = relative(40 * 86_400)
        #expect(!old.contains("ago"))
        #expect(old.contains("Oct"))
    }
}
