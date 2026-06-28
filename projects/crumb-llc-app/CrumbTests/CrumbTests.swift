import Testing
import CrumbKit
@testable import Crumb

/// App-level smoke tests (run via Xcode). These exercise `AppModel` routing on top of the
/// mock UCP client — no network, no secrets.
@Suite("Crumb app smoke tests")
struct CrumbTests {

    @Test("App starts on the Missions route with three seed missions")
    @MainActor
    func launchesToMissions() {
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        #expect(model.route == .missions)
        #expect(model.missions.count == 3)
        #expect(model.kit.isEmpty)
    }

    @Test("startMission(matching:) routes to Plan with a resolved mission")
    @MainActor
    func startMissionRoutesToPlan() {
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        model.startMission(matching: "pack me for a rainy hike")
        #expect(model.route == .plan)
        #expect(model.selectedTask?.id == "hike")
    }

    @Test("Unknown phrases fall back to the hike mission")
    @MainActor
    func startMissionFallsBack() {
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        model.startMission(matching: "qwerty nonsense")
        #expect(model.selectedTask?.id == "hike")
    }

    @Test("Accepting a product adds it to the kit once")
    @MainActor
    func acceptBuildsKit() throws {
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        let product = try #require(SeedData.hikeProducts.first)
        model.accept(product)
        model.accept(product) // idempotent by product id
        #expect(model.kit.count == 1)
        #expect(model.isInKit(product))
    }

    @Test("MockUCPClient.searchCatalog(\"hike\") returns the hike candidates")
    func searchHike() async throws {
        let hits = try await MockUCPClient().searchCatalog("hike", placements: [.organic])
        #expect(hits.count == 6)
        #expect(hits.allSatisfy { $0.id.hasPrefix("hike.") })
    }
}
