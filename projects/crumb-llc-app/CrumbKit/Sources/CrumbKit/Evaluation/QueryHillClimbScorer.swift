import Foundation

public enum QueryAltitude: String, Codable, Sendable {
    case singleItem
    case multiPart
    case notShoppable
}

public struct ShoppingQueryCorpus: Codable, Sendable {
    public let schemaVersion: Int
    public let description: String
    public let cases: [ShoppingQueryCase]
}

public struct ShoppingQueryCase: Codable, Sendable {
    public let id: String
    public let category: String
    public let goal: String
    public let tasteProfile: ShoppingQueryTasteProfile?
    public let expectedAltitude: QueryAltitude
    public let requiredQueryTerms: [String]?
    public let allowedQueryTerms: [String]?
    public let forbiddenQueryTerms: [String]
    public let requiredPartConcepts: [String]?
    public let canonicalQueries: [String]

    public init(
        id: String, category: String, goal: String,
        tasteProfile: ShoppingQueryTasteProfile? = nil,
        expectedAltitude: QueryAltitude, requiredQueryTerms: [String]?,
        allowedQueryTerms: [String]?, forbiddenQueryTerms: [String],
        requiredPartConcepts: [String]?, canonicalQueries: [String]
    ) {
        self.id = id
        self.category = category
        self.goal = goal
        self.tasteProfile = tasteProfile
        self.expectedAltitude = expectedAltitude
        self.requiredQueryTerms = requiredQueryTerms
        self.allowedQueryTerms = allowedQueryTerms
        self.forbiddenQueryTerms = forbiddenQueryTerms
        self.requiredPartConcepts = requiredPartConcepts
        self.canonicalQueries = canonicalQueries
    }
}

public struct ShoppingQueryTasteProfile: Codable, Sendable {
    public let vibe: [String]?
    public let leanings: [String]?
    public let budgetComfort: Double?
    public let signatureLine: String?

    public func resolved(fallback: TasteProfile = SeedData.defaultTasteProfile) -> TasteProfile {
        TasteProfile(
            vibe: vibe ?? fallback.vibe,
            leanings: leanings ?? fallback.leanings,
            budgetComfort: budgetComfort ?? fallback.budgetComfort,
            signatureLine: signatureLine ?? fallback.signatureLine
        ).normalized
    }
}

public struct QueryPlanningObservationFile: Codable, Sendable {
    public let schemaVersion: Int
    public let promptID: String
    public let runs: [QueryPlanningObservation]

    public init(schemaVersion: Int = 1, promptID: String, runs: [QueryPlanningObservation]) {
        self.schemaVersion = schemaVersion
        self.promptID = promptID
        self.runs = runs
    }
}

public struct QueryPlanningObservation: Codable, Sendable {
    public let caseID: String
    public let runID: String
    public let isShoppable: Bool
    public let isSingleItem: Bool?
    public let queries: [String]
    public let plannerTier: String?
    public let fallbackReason: String?

    public init(caseID: String, runID: String, isShoppable: Bool,
                isSingleItem: Bool?, queries: [String], plannerTier: String? = nil,
                fallbackReason: String? = nil) {
        self.caseID = caseID
        self.runID = runID
        self.isShoppable = isShoppable
        self.isSingleItem = isSingleItem
        self.queries = queries
        self.plannerTier = plannerTier
        self.fallbackReason = fallbackReason
    }
}

public struct ScoreComponent: Codable, Sendable {
    public let name: String
    public let earned: Double
    public let possible: Double
}

public struct CaseRunScore: Codable, Sendable {
    public let caseID: String
    public let runID: String
    public let category: String
    public let score: Double
    public let components: [ScoreComponent]
    public let missingTerms: [String]
    public let forbiddenTermsFound: [String]
    public let criticalPass: Bool
    public let altitudeCorrect: Bool
    public let forbiddenLeakage: Bool
    public let requiredRecall: Double
    public let plannerTier: String?
}

public struct CategoryScoreSummary: Codable, Sendable {
    public let category: String
    public let samples: Int
    public let mean: Double
    public let criticalPassRate: Double
    public let forbiddenLeakageRate: Double
}

public struct HillClimbReport: Codable, Sendable {
    public let promptID: String
    public let corpusCases: Int
    public let cases: Int
    public let coveragePercent: Double
    public let samples: Int
    public let headlineScore: Double
    public let mean: Double
    public let median: Double
    public let tenthPercentile: Double
    public let criticalPassRate: Double
    public let perfectRate: Double
    public let altitudeAccuracy: Double
    public let requiredRecall: Double
    public let forbiddenLeakageRate: Double
    public let modelRunRate: Double
    public let plannerTierCounts: [String: Int]
    public let categories: [CategoryScoreSummary]
    public let worstRuns: [CaseRunScore]
    public let runs: [CaseRunScore]
}

public enum QueryHillClimbError: Error, CustomStringConvertible {
    case unsupportedCorpusSchema(Int)
    case unsupportedObservationSchema(Int)
    case duplicateCaseID(String)
    case duplicateRun(String)
    case unknownCaseID(String)
    case noObservations
    case invalidCorpusCase(String, String)
    case incompleteCoverage(missing: [String])
    case unevenRunCounts([String: Int])
    case blankRunID(String)

    public var description: String {
        switch self {
        case let .unsupportedCorpusSchema(version): "unsupported corpus schema version: \(version)"
        case let .unsupportedObservationSchema(version): "unsupported observation schema version: \(version)"
        case let .duplicateCaseID(id): "duplicate corpus case id: \(id)"
        case let .duplicateRun(id): "duplicate observation case/run pair: \(id)"
        case let .unknownCaseID(id): "observation references unknown case id: \(id)"
        case .noObservations: "observation file contains no runs"
        case let .invalidCorpusCase(id, reason): "invalid corpus case '\(id)': \(reason)"
        case let .incompleteCoverage(missing): "observations do not cover the complete corpus; missing: \(missing.joined(separator: ", "))"
        case let .unevenRunCounts(counts): "observations have uneven per-case run counts: \(counts.keys.sorted().map { "\($0)=\(counts[$0]!)" }.joined(separator: ", "))"
        case let .blankRunID(id): "observation for case '\(id)' has a blank run id"
        }
    }
}

public enum QueryHillClimbScorer {
    public static func report(corpus: ShoppingQueryCorpus,
                              observations: QueryPlanningObservationFile,
                              allowPartial: Bool = false) throws -> HillClimbReport {
        guard corpus.schemaVersion == 1 else { throw QueryHillClimbError.unsupportedCorpusSchema(corpus.schemaVersion) }
        guard observations.schemaVersion == 1 else {
            throw QueryHillClimbError.unsupportedObservationSchema(observations.schemaVersion)
        }
        guard !observations.runs.isEmpty else { throw QueryHillClimbError.noObservations }

        var casesByID: [String: ShoppingQueryCase] = [:]
        for testCase in corpus.cases {
            try validate(testCase)
            guard casesByID.updateValue(testCase, forKey: testCase.id) == nil else {
                throw QueryHillClimbError.duplicateCaseID(testCase.id)
            }
        }
        var seenRuns = Set<String>()
        var scores: [CaseRunScore] = []
        for observation in observations.runs {
            guard let testCase = casesByID[observation.caseID] else {
                throw QueryHillClimbError.unknownCaseID(observation.caseID)
            }
            guard !observation.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw QueryHillClimbError.blankRunID(observation.caseID)
            }
            let key = observation.caseID + "\u{1f}" + observation.runID
            guard seenRuns.insert(key).inserted else { throw QueryHillClimbError.duplicateRun(key) }
            scores.append(score(testCase, observation: observation))
        }
        if !allowPartial {
            let observedIDs = Set(observations.runs.map(\.caseID))
            let missing = Set(casesByID.keys).subtracting(observedIDs).sorted()
            guard missing.isEmpty else { throw QueryHillClimbError.incompleteCoverage(missing: missing) }
            let counts = Dictionary(grouping: observations.runs, by: \.caseID).mapValues(\.count)
            guard Set(counts.values).count == 1 else { throw QueryHillClimbError.unevenRunCounts(counts) }
        }
        return aggregate(promptID: observations.promptID, corpusCases: corpus.cases.count, scores: scores)
    }

    public static func score(_ testCase: ShoppingQueryCase,
                             observation: QueryPlanningObservation) -> CaseRunScore {
        let usable = observation.queries.map(normalize).filter { !$0.isEmpty }
        let forbidden = testCase.forbiddenQueryTerms.filter { term in
            usable.contains { matches(term, in: $0) }
        }
        let altitudeCorrect: Bool = switch testCase.expectedAltitude {
        case .singleItem: observation.isShoppable && observation.isSingleItem == true
        case .multiPart: observation.isShoppable && observation.isSingleItem == false
        case .notShoppable: !observation.isShoppable
        }

        if testCase.expectedAltitude == .notShoppable {
            let value = !observation.isShoppable ? (usable.isEmpty ? 100.0 : 50.0) : 0.0
            return CaseRunScore(
                caseID: testCase.id, runID: observation.runID, category: testCase.category,
                score: value, components: [ScoreComponent(name: "notShoppable", earned: value, possible: 100)],
                missingTerms: [], forbiddenTermsFound: forbidden, criticalPass: value == 100,
                altitudeCorrect: altitudeCorrect, forbiddenLeakage: !forbidden.isEmpty, requiredRecall: 100,
                plannerTier: observation.plannerTier
            )
        }

        let required = testCase.expectedAltitude == .singleItem
            ? (testCase.requiredQueryTerms ?? []) : (testCase.requiredPartConcepts ?? [])
        let missing = required.filter { term in
            !usable.contains { matchesConcept(term, in: $0) }
        }
        let recall = required.isEmpty ? 1.0 : Double(required.count - missing.count) / Double(required.count)
        let shoppable = observation.isShoppable ? 10.0 : 0
        let altitude = altitudeCorrect ? 15.0 : 0
        var components: [ScoreComponent]
        var total: Double

        if testCase.expectedAltitude == .singleItem {
            let count = usable.count == 1 ? 10.0 : 0
            let requiredPoints = 35.0 * recall
            let safe = forbidden.isEmpty ? 20.0 : 0
            let hygiene = usable.count == 1 && isHygienic(usable[0]) ? 5.0 : 0
            let canonical = 5.0 * canonicalSimilarity(usable.first ?? "", testCase.canonicalQueries)
            components = [
                .init(name: "shoppable", earned: shoppable, possible: 10),
                .init(name: "altitude", earned: altitude, possible: 15),
                .init(name: "queryCount", earned: count, possible: 10),
                .init(name: "requiredTerms", earned: requiredPoints, possible: 35),
                .init(name: "forbiddenSafety", earned: safe, possible: 20),
                .init(name: "hygiene", earned: hygiene, possible: 5),
                .init(name: "canonicalSimilarity", earned: canonical, possible: 5),
            ]
            total = shoppable + altitude + count + requiredPoints + safe + hygiene + canonical
        } else {
            let coverage = 45.0 * recall
            let safe = forbidden.isEmpty ? 15.0 : 0
            let unique = Set(usable)
            let distinct = usable.count >= 2 && unique.count == usable.count ? 10.0 : 0
            let upper = max(6, testCase.canonicalQueries.count + 1)
            let reasonable = (2...upper).contains(usable.count) ? 5.0 : 0
            components = [
                .init(name: "shoppable", earned: shoppable, possible: 10),
                .init(name: "altitude", earned: altitude, possible: 15),
                .init(name: "requiredConcepts", earned: coverage, possible: 45),
                .init(name: "forbiddenSafety", earned: safe, possible: 15),
                .init(name: "distinctQueries", earned: distinct, possible: 10),
                .init(name: "queryCount", earned: reasonable, possible: 5),
            ]
            total = shoppable + altitude + coverage + safe + distinct + reasonable
        }

        if !observation.isShoppable { total = min(total, 25) }
        if usable.isEmpty { total = min(total, 30) }
        if !altitudeCorrect { total = min(total, 70) }
        if !forbidden.isEmpty { total = min(total, 80) }
        let uniqueQueries = Set(usable)
        let usableCount: Bool
        if testCase.expectedAltitude == .singleItem {
            usableCount = usable.count == 1
        } else {
            let matchesPerQuery = uniqueQueries.map { query in
                required.filter { matchesConcept($0, in: query) }.count
            }
            // A kit must really be decomposed. Repeating one query, or stuffing every concept
            // into one giant query plus filler, is not a critical pass.
            usableCount = uniqueQueries.count >= 2
                && matchesPerQuery.filter({ $0 > 0 }).count >= 2
                && (matchesPerQuery.max() ?? 0) < required.count
        }
        let critical = observation.isShoppable && altitudeCorrect && missing.isEmpty
            && forbidden.isEmpty && usableCount
        return CaseRunScore(
            caseID: testCase.id, runID: observation.runID, category: testCase.category,
            score: total, components: components, missingTerms: missing,
            forbiddenTermsFound: forbidden, criticalPass: critical, altitudeCorrect: altitudeCorrect,
            forbiddenLeakage: !forbidden.isEmpty, requiredRecall: recall * 100,
            plannerTier: observation.plannerTier
        )
    }

    public static func textReport(_ report: HillClimbReport) -> String {
        func f(_ value: Double) -> String { String(format: "%.1f", value) }
        var lines = [
            "Query hill-climb report: \(report.promptID)",
            "Cases: \(report.cases)/\(report.corpusCases)  Coverage: \(f(report.coveragePercent))%  Samples: \(report.samples)",
            "Headline: \(f(report.headlineScore))",
            "Mean: \(f(report.mean))  Median: \(f(report.median))  P10: \(f(report.tenthPercentile))",
            "Critical pass: \(f(report.criticalPassRate))%  Perfect: \(f(report.perfectRate))%",
            "Altitude accuracy: \(f(report.altitudeAccuracy))%  Required recall: \(f(report.requiredRecall))%",
            "Forbidden leakage: \(f(report.forbiddenLeakageRate))%",
            "Model runs: \(f(report.modelRunRate))%  Tiers: \(report.plannerTierCounts.keys.sorted().map { "\($0)=\(report.plannerTierCounts[$0]!)" }.joined(separator: ", "))",
            "",
            "Categories:",
        ]
        for category in report.categories {
            lines.append("  \(category.category): n=\(category.samples) mean=\(f(category.mean)) pass=\(f(category.criticalPassRate))% leakage=\(f(category.forbiddenLeakageRate))%")
        }
        lines.append("")
        lines.append("Worst runs:")
        for run in report.worstRuns {
            var reasons: [String] = []
            if !run.missingTerms.isEmpty { reasons.append("missing=" + run.missingTerms.joined(separator: ",")) }
            if !run.forbiddenTermsFound.isEmpty { reasons.append("forbidden=" + run.forbiddenTermsFound.joined(separator: ",")) }
            if !run.altitudeCorrect { reasons.append("wrong-altitude") }
            let suffix = reasons.isEmpty ? "" : " " + reasons.joined(separator: " ")
            lines.append("  \(run.caseID)/\(run.runID): \(f(run.score))\(suffix)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let pieces = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(pieces).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func matches(_ phrase: String, in text: String) -> Bool {
        let haystack = normalize(text).split(separator: " ").map(String.init)
        return variants(for: phrase).contains { variant in
            let needle = normalize(variant).split(separator: " ").map(String.init)
            guard !needle.isEmpty, needle.count <= haystack.count else { return false }
            return (0...(haystack.count - needle.count)).contains { start in
                Array(haystack[start..<(start + needle.count)]) == needle
            }
        }
    }

    /// Semantic constraint matching stays deterministic but permits catalog-friendly
    /// adjective insertion and word-order changes: "dog bed" matches "senior dog orthopedic
    /// bed", while every token still has to appear as a complete word in one query.
    public static func matchesConcept(_ concept: String, in query: String) -> Bool {
        if matches(concept, in: query) { return true }
        let queryTokens = Set(normalize(query).split(separator: " ").map { singular(String($0)) })
        return variants(for: concept).contains { variant in
            let conceptTokens = normalize(variant).split(separator: " ").map { singular(String($0)) }
            return !conceptTokens.isEmpty && conceptTokens.allSatisfy(queryTokens.contains)
        }
    }

    private static func variants(for phrase: String) -> [String] {
        let value = normalize(phrase)
        let aliases: [String: [String]] = [
            "women": ["women", "womens", "woman"],
            "usb c": ["usb c", "usbc"],
            "cat safe": ["cat safe", "safe for cats", "pet safe"],
            "carry on luggage": ["carry on luggage", "carryon luggage"],
        ]
        if let direct = aliases[value] { return direct }
        if let match = value.wholeMatch(of: /under (\d+)/) {
            let number = String(match.1)
            return [value, "below \(number)", "less than \(number)"]
        }
        let pieces = value.split(separator: " ")
        if pieces.count == 2, pieces[1] == "inch", pieces[0].allSatisfy(\.isNumber) {
            return [value, "\(pieces[0])in"]
        }
        return [value]
    }

    private static func singular(_ token: String) -> String {
        guard token.count > 3, token.hasSuffix("s"), !token.hasSuffix("ss") else { return token }
        return String(token.dropLast())
    }

    private static func isHygienic(_ query: String) -> Bool {
        let tokens = normalize(query).split(separator: " ").map(String.init)
        return !tokens.isEmpty && tokens.count <= 8 && Set(tokens).count == tokens.count
    }

    private static func canonicalSimilarity(_ query: String, _ canonicals: [String]) -> Double {
        let queryTokens = Set(normalize(query).split(separator: " ").map(String.init))
        guard !queryTokens.isEmpty else { return 0 }
        return canonicals.map { canonical -> Double in
            let tokens = Set(normalize(canonical).split(separator: " ").map(String.init))
            let union = queryTokens.union(tokens).count
            return union == 0 ? 0 : Double(queryTokens.intersection(tokens).count) / Double(union)
        }.max() ?? 0
    }

    private static func validate(_ testCase: ShoppingQueryCase) throws {
        let id = testCase.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw QueryHillClimbError.invalidCorpusCase("<blank>", "id is blank") }
        guard !testCase.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QueryHillClimbError.invalidCorpusCase(id, "category is blank")
        }
        guard !testCase.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QueryHillClimbError.invalidCorpusCase(id, "goal is blank")
        }
        let lists: [(String, [String])] = [
            ("requiredQueryTerms", testCase.requiredQueryTerms ?? []),
            ("allowedQueryTerms", testCase.allowedQueryTerms ?? []),
            ("forbiddenQueryTerms", testCase.forbiddenQueryTerms),
            ("requiredPartConcepts", testCase.requiredPartConcepts ?? []),
            ("canonicalQueries", testCase.canonicalQueries),
        ]
        for (name, values) in lists where values.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            throw QueryHillClimbError.invalidCorpusCase(id, "\(name) contains a blank value")
        }
        switch testCase.expectedAltitude {
        case .singleItem:
            guard !(testCase.requiredQueryTerms ?? []).isEmpty else {
                throw QueryHillClimbError.invalidCorpusCase(id, "singleItem requires requiredQueryTerms")
            }
            guard (testCase.requiredPartConcepts ?? []).isEmpty else {
                throw QueryHillClimbError.invalidCorpusCase(id, "singleItem cannot have requiredPartConcepts")
            }
            guard !testCase.canonicalQueries.isEmpty else {
                throw QueryHillClimbError.invalidCorpusCase(id, "singleItem requires a canonical query")
            }
        case .multiPart:
            guard !(testCase.requiredPartConcepts ?? []).isEmpty else {
                throw QueryHillClimbError.invalidCorpusCase(id, "multiPart requires requiredPartConcepts")
            }
            guard (testCase.requiredQueryTerms ?? []).isEmpty else {
                throw QueryHillClimbError.invalidCorpusCase(id, "multiPart cannot have requiredQueryTerms")
            }
            guard testCase.canonicalQueries.count >= 2 else {
                throw QueryHillClimbError.invalidCorpusCase(id, "multiPart requires at least two canonical queries")
            }
        case .notShoppable:
            guard (testCase.requiredQueryTerms ?? []).isEmpty,
                  (testCase.requiredPartConcepts ?? []).isEmpty,
                  testCase.canonicalQueries.isEmpty else {
                throw QueryHillClimbError.invalidCorpusCase(id, "notShoppable cannot define required terms, concepts, or canonical queries")
            }
        }
    }

    private static func aggregate(promptID: String, corpusCases: Int,
                                  scores: [CaseRunScore]) -> HillClimbReport {
        let byCase = Dictionary(grouping: scores, by: \.caseID)
        // Macro-average cases so adding extra stochastic runs to one case cannot give it more
        // influence than another case in a diagnostic partial report.
        let caseScores = byCase.values.map { average($0.map(\.score)) }
        let ordered = caseScores.sorted()
        let mean = average(ordered)
        let median: Double = ordered.count.isMultiple(of: 2)
            ? (ordered[ordered.count / 2 - 1] + ordered[ordered.count / 2]) / 2
            : ordered[ordered.count / 2]
        let p10Index = max(0, Int(ceil(Double(ordered.count) * 0.10)) - 1)
        let p10 = ordered[p10Index]
        let pass = average(byCase.values.map { percentage($0.filter(\.criticalPass).count, $0.count) })
        let leakage = average(byCase.values.map { percentage($0.filter(\.forbiddenLeakage).count, $0.count) })
        let tierCounts = Dictionary(grouping: scores, by: { $0.plannerTier ?? "unknown" }).mapValues(\.count)
        let modelRuns = (tierCounts["onDevice"] ?? 0) + (tierCounts["privateCloud"] ?? 0)
        let headline = min(100, max(0, 0.5 * mean + 0.25 * p10 + 0.25 * pass - 2 * leakage))
        let grouped = Dictionary(grouping: scores, by: \.category)
        let categories = grouped.keys.sorted().map { category in
            let group = grouped[category]!
            let categoryCases = Dictionary(grouping: group, by: \.caseID)
            return CategoryScoreSummary(
                category: category, samples: group.count,
                mean: average(categoryCases.values.map { average($0.map(\.score)) }),
                criticalPassRate: average(categoryCases.values.map { percentage($0.filter(\.criticalPass).count, $0.count) }),
                forbiddenLeakageRate: average(categoryCases.values.map { percentage($0.filter(\.forbiddenLeakage).count, $0.count) })
            )
        }
        let worst = scores.sorted {
            $0.score == $1.score ? ($0.caseID, $0.runID) < ($1.caseID, $1.runID) : $0.score < $1.score
        }.prefix(10)
        return HillClimbReport(
            promptID: promptID, corpusCases: corpusCases, cases: byCase.count,
            coveragePercent: percentage(byCase.count, corpusCases), samples: scores.count,
            headlineScore: headline, mean: mean, median: median, tenthPercentile: p10,
            criticalPassRate: pass,
            perfectRate: average(byCase.values.map { percentage($0.filter { $0.score == 100 }.count, $0.count) }),
            altitudeAccuracy: average(byCase.values.map { percentage($0.filter(\.altitudeCorrect).count, $0.count) }),
            requiredRecall: average(byCase.values.map { average($0.map(\.requiredRecall)) }),
            forbiddenLeakageRate: leakage,
            modelRunRate: percentage(modelRuns, scores.count), plannerTierCounts: tierCounts,
            categories: categories, worstRuns: Array(worst), runs: scores
        )
    }

    private static func average(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    private static func percentage(_ numerator: Int, _ denominator: Int) -> Double {
        100 * Double(numerator) / Double(denominator)
    }
}
