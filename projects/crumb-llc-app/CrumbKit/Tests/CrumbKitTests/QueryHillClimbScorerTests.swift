import Foundation
import Testing
@testable import CrumbKit

@Suite("Query hill-climb scorer")
struct QueryHillClimbScorerTests {
    private func corpus() throws -> ShoppingQueryCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/shopping_query_cases.json")
        return try JSONDecoder().decode(
            ShoppingQueryCorpus.self,
            from: Data(contentsOf: fixture)
        )
    }

    private func observationFixture(_ name: String) throws -> QueryPlanningObservationFile {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try JSONDecoder().decode(QueryPlanningObservationFile.self, from: Data(contentsOf: url))
    }

    private func observation(
        for testCase: ShoppingQueryCase,
        runID: String = "run-1",
        queries: [String]? = nil,
        shoppable: Bool? = nil,
        singleItem: Bool? = nil
    ) -> QueryPlanningObservation {
        QueryPlanningObservation(
            caseID: testCase.id,
            runID: runID,
            isShoppable: shoppable ?? (testCase.expectedAltitude != .notShoppable),
            isSingleItem: singleItem ?? {
                switch testCase.expectedAltitude {
                case .singleItem: true
                case .multiPart: false
                case .notShoppable: nil
                }
            }(),
            queries: queries ?? testCase.canonicalQueries
        )
    }

    @Test("The checked-in corpus decodes completely and has unique IDs")
    func corpusIntegrity() throws {
        let value = try corpus()
        #expect(value.schemaVersion == 1)
        #expect(value.cases.count == 76)
        #expect(Set(value.cases.map(\.id)).count == value.cases.count)
        #expect(value.cases.filter { $0.expectedAltitude == .singleItem }.count == 57)
        #expect(value.cases.filter { $0.expectedAltitude == .multiPart }.count == 15)
        #expect(value.cases.filter { $0.expectedAltitude == .notShoppable }.count == 4)
    }

    @Test("Taste overrides decode and resolve without losing default fields")
    func tasteOverrides() throws {
        let value = try corpus()
        let testCase = try #require(value.cases.first { $0.id == "tea-jasmine-merino-leak" })
        let taste = try #require(testCase.tasteProfile).resolved()
        #expect(taste.vibe == ["Quiet", "Earthy"])
        #expect(taste.leanings == ["Merino over synthetic", "Muted tones"])
        #expect(taste.budgetComfort == 0.6)
        #expect(taste.signatureLine == SeedData.defaultTasteProfile.signatureLine)
    }

    @Test("Canonical observations give every corpus case a critical pass")
    func canonicalCorpusPasses() throws {
        let value = try corpus()
        let observations = QueryPlanningObservationFile(
            promptID: "canonical",
            runs: value.cases.map { observation(for: $0) }
        )
        let report = try QueryHillClimbScorer.report(corpus: value, observations: observations)

        #expect(report.cases == 76)
        #expect(report.samples == 76)
        #expect(report.altitudeAccuracy == 100)
        #expect(report.requiredRecall == 100)
        #expect(report.forbiddenLeakageRate == 0)
        #expect(report.criticalPassRate == 100)
        #expect(report.runs.allSatisfy { $0.criticalPass })
    }

    @Test("Jasmine scoring distinguishes healthy, lossy, generic, and taste-leaking queries")
    func jasmineRegression() throws {
        let value = try corpus()
        let testCase = try #require(value.cases.first { $0.id == "tea-jasmine-merino-leak" })

        let healthy = QueryHillClimbScorer.score(
            testCase, observation: observation(for: testCase, queries: ["jasmine tea premium"])
        )
        let lossy = QueryHillClimbScorer.score(
            testCase, observation: observation(for: testCase, queries: ["jasmine tea"])
        )
        let generic = QueryHillClimbScorer.score(
            testCase, observation: observation(for: testCase, queries: ["tea"])
        )
        let leaked = QueryHillClimbScorer.score(
            testCase, observation: observation(for: testCase, queries: ["jasmine tea merino"])
        )

        #expect(healthy.score == 100)
        #expect(lossy.score < healthy.score)
        #expect(!lossy.criticalPass)
        #expect(lossy.missingTerms == ["premium"])
        #expect(generic.missingTerms == ["premium", "jasmine"])
        #expect(!generic.criticalPass)
        #expect(leaked.forbiddenTermsFound == ["merino"])
        #expect(leaked.forbiddenLeakage)
        #expect(leaked.score <= 80)
        #expect(!leaked.criticalPass)
    }

    @Test("Matching is normalized, phrase-aware, synonym-aware, and token-boundary safe")
    func matchingSemantics() {
        #expect(QueryHillClimbScorer.matches("usb c", in: "Compact 65W USB-C GaN charger"))
        #expect(QueryHillClimbScorer.matches("cat safe", in: "low light plant safe for cats"))
        #expect(QueryHillClimbScorer.matches("under 100", in: "headphones below $100"))
        #expect(QueryHillClimbScorer.matches("12 inch", in: "12in cast iron skillet"))
        #expect(QueryHillClimbScorer.matches("tea", in: "premium jasmine tea"))
        #expect(!QueryHillClimbScorer.matches("tea", in: "teapot"))
        #expect(!QueryHillClimbScorer.matches("cat", in: "catalog"))
    }

    @Test("Hard failure caps prevent superficially healthy scores")
    func hardFailureCaps() throws {
        let value = try corpus()
        let testCase = try #require(value.cases.first { $0.id == "tea-jasmine-merino-leak" })

        let declined = QueryHillClimbScorer.score(
            testCase,
            observation: observation(for: testCase, queries: ["premium jasmine tea"], shoppable: false)
        )
        let empty = QueryHillClimbScorer.score(
            testCase, observation: observation(for: testCase, queries: [])
        )
        let wrongAltitude = QueryHillClimbScorer.score(
            testCase,
            observation: observation(for: testCase, queries: ["premium jasmine tea"], singleItem: false)
        )

        #expect(declined.score <= 25)
        #expect(empty.score <= 30)
        #expect(wrongAltitude.score <= 70)
        #expect(!declined.criticalPass && !empty.criticalPass && !wrongAltitude.criticalPass)
    }

    @Test("Multi-part coverage is computed across distinct queries")
    func multiPartCoverage() throws {
        let value = try corpus()
        let testCase = try #require(value.cases.first { $0.id == "kit-lacrosse-premium" })
        let partial = QueryHillClimbScorer.score(
            testCase,
            observation: observation(
                for: testCase,
                queries: ["lacrosse stick", "lacrosse helmet", "lacrosse gloves"]
            )
        )
        let duplicate = QueryHillClimbScorer.score(
            testCase,
            observation: observation(
                for: testCase,
                queries: ["lacrosse stick", "lacrosse stick"]
            )
        )

        #expect(partial.requiredRecall == 50)
        #expect(Set(partial.missingTerms) == Set(["shoulder pads", "arm pads", "lacrosse cleats"]))
        #expect(!partial.criticalPass)
        #expect(duplicate.components.first { $0.name == "distinctQueries" }?.earned == 0)
        #expect(!duplicate.criticalPass)

        let giant = QueryHillClimbScorer.score(
            testCase,
            observation: observation(
                for: testCase,
                queries: [
                    "lacrosse stick helmet gloves shoulder pads arm pads cleats",
                    "premium sports equipment",
                ]
            )
        )
        #expect(giant.requiredRecall == 100)
        #expect(!giant.criticalPass)
    }

    @Test("Non-shopping cases require both a decline and no generated query")
    func nonShopping() throws {
        let value = try corpus()
        let testCase = try #require(value.cases.first { $0.id == "nonshopping-question" })
        let clean = QueryHillClimbScorer.score(testCase, observation: observation(for: testCase))
        let queryDespiteDecline = QueryHillClimbScorer.score(
            testCase, observation: observation(for: testCase, queries: ["sky book"])
        )
        let misclassified = QueryHillClimbScorer.score(
            testCase,
            observation: observation(
                for: testCase, queries: ["sky book"], shoppable: true, singleItem: true
            )
        )

        #expect(clean.score == 100 && clean.criticalPass)
        #expect(queryDespiteDecline.score == 50 && !queryDespiteDecline.criticalPass)
        #expect(misclassified.score == 0 && !misclassified.criticalPass)
    }

    @Test("Aggregation reports stochastic failures and penalizes leakage in the headline")
    func aggregateMetrics() throws {
        let value = try corpus()
        let testCase = try #require(value.cases.first { $0.id == "tea-jasmine-merino-leak" })
        let observations = QueryPlanningObservationFile(
            promptID: "planner-v1",
            runs: [
                observation(for: testCase, runID: "good", queries: ["premium jasmine tea"]),
                observation(for: testCase, runID: "leak", queries: ["jasmine tea merino"]),
            ]
        )
        let report = try QueryHillClimbScorer.report(
            corpus: value, observations: observations, allowPartial: true
        )

        #expect(report.cases == 1 && report.samples == 2)
        #expect(report.forbiddenLeakageRate == 50)
        #expect(report.criticalPassRate == 50)
        #expect(report.worstRuns.first?.runID == "leak")
        #expect(report.headlineScore < report.mean)
        #expect(QueryHillClimbScorer.textReport(report).contains("forbidden=merino"))
    }


    @Test("Strict reports require complete, evenly sampled corpus coverage")
    func strictCoverage() throws {
        let value = try corpus()
        let first = try #require(value.cases.first)
        #expect(throws: QueryHillClimbError.self) {
            try QueryHillClimbScorer.report(
                corpus: value,
                observations: QueryPlanningObservationFile(
                    promptID: "partial", runs: [observation(for: first)]
                )
            )
        }

        var runs = value.cases.map { observation(for: $0) }
        runs.append(observation(for: first, runID: "run-2"))
        #expect(throws: QueryHillClimbError.self) {
            try QueryHillClimbScorer.report(
                corpus: value,
                observations: QueryPlanningObservationFile(promptID: "uneven", runs: runs)
            )
        }

        let partial = try QueryHillClimbScorer.report(
            corpus: value,
            observations: QueryPlanningObservationFile(
                promptID: "partial", runs: [observation(for: first)]
            ),
            allowPartial: true
        )
        #expect(partial.cases == 1 && partial.corpusCases == 76)
        #expect(partial.coveragePercent > 1 && partial.coveragePercent < 2)
    }

    @Test("Checked-in strong and adversarial observations are clearly discriminated")
    func observationFixturesDiscriminate() throws {
        let value = try corpus()
        let strong = try QueryHillClimbScorer.report(
            corpus: value,
            observations: observationFixture("shopping_query_observations_strong"),
            allowPartial: true
        )
        let adversarial = try QueryHillClimbScorer.report(
            corpus: value,
            observations: observationFixture("shopping_query_observations_adversarial"),
            allowPartial: true
        )
        #expect(strong.coveragePercent == adversarial.coveragePercent)
        #expect(strong.headlineScore > adversarial.headlineScore + 30)
        #expect(strong.criticalPassRate > adversarial.criticalPassRate)
        #expect(adversarial.forbiddenLeakageRate > strong.forbiddenLeakageRate)
    }

    @Test("Malformed corpus and observation files fail explicitly")
    func validationErrors() throws {
        let value = try corpus()
        let testCase = try #require(value.cases.first)
        let validRun = observation(for: testCase)

        #expect(throws: QueryHillClimbError.self) {
            try QueryHillClimbScorer.report(
                corpus: value,
                observations: QueryPlanningObservationFile(promptID: "empty", runs: [])
            )
        }
        #expect(throws: QueryHillClimbError.self) {
            try QueryHillClimbScorer.report(
                corpus: value,
                observations: QueryPlanningObservationFile(promptID: "dupe", runs: [validRun, validRun])
            )
        }
        let unknown = QueryPlanningObservation(
            caseID: "does-not-exist", runID: "1", isShoppable: true,
            isSingleItem: true, queries: ["something"]
        )
        #expect(throws: QueryHillClimbError.self) {
            try QueryHillClimbScorer.report(
                corpus: value,
                observations: QueryPlanningObservationFile(promptID: "unknown", runs: [unknown])
            )
        }
    }

    @Test("Corpus validation rejects blank terms and altitude-specific field mistakes")
    func invalidCorpusCases() throws {
        let value = try corpus()
        let source = try #require(value.cases.first { $0.expectedAltitude == .singleItem })
        let invalid = ShoppingQueryCase(
            id: source.id, category: source.category, goal: source.goal,
            expectedAltitude: .singleItem, requiredQueryTerms: [" "],
            allowedQueryTerms: [], forbiddenQueryTerms: [], requiredPartConcepts: ["kit"],
            canonicalQueries: source.canonicalQueries
        )
        let invalidCorpus = ShoppingQueryCorpus(
            schemaVersion: 1, description: "invalid", cases: [invalid]
        )
        #expect(throws: QueryHillClimbError.self) {
            try QueryHillClimbScorer.report(
                corpus: invalidCorpus,
                observations: QueryPlanningObservationFile(
                    promptID: "invalid", runs: [observation(for: invalid)]
                )
            )
        }
    }
}
