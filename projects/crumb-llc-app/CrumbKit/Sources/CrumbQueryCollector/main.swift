import CrumbKit
import Foundation

private struct Options {
    let casesPath: String
    let outputDirectory: String
    let promptID: String
    let runs: Int
    let limit: Int?
    let caseIDs: Set<String>
    let resume: Bool
    let requireModel: Bool
}

private struct RawPlannerRun: Codable {
    let caseID: String
    let runID: String
    let goal: String
    let startedAt: Date
    let elapsedMilliseconds: Int
    let tier: String
    let fallbackNote: String?
    let isShoppable: Bool
    let isSingleItem: Bool?
    let title: String?
    let subtitle: String?
    let plan: [String]
    let queries: [String]
    let decline: String?
    let tasteProfile: TasteProfile
}

private enum CollectorError: Error, CustomStringConvertible {
    case usage(String)
    case invalid(String)

    var description: String {
        switch self {
        case let .usage(message), let .invalid(message): message
        }
    }
}

private func usage() -> String {
    """
    Usage: crumb-query-collect --cases PATH --output DIR --prompt-id ID [options]

      --runs N          Generations per case (default: 5)
      --limit N         Evaluate only the first N selected cases (smoke/diagnostic mode)
      --case ID         Evaluate one case ID; repeatable
      --no-resume       Replace prior observations instead of resuming them
      --require-model   Persist runs, then fail if any degraded to rule-based
    """
}

private func parseArguments(_ arguments: [String]) throws -> Options {
    if arguments.contains("--help") || arguments.contains("-h") {
        print(usage())
        exit(0)
    }
    var casesPath: String?
    var output: String?
    var promptID: String?
    var runs = 5
    var limit: Int?
    var caseIDs = Set<String>()
    var resume = true
    var requireModel = false
    var index = 0

    func value(after flag: String) throws -> String {
        guard index + 1 < arguments.count else {
            throw CollectorError.usage("Missing value for \(flag)\n\(usage())")
        }
        return arguments[index + 1]
    }

    while index < arguments.count {
        let flag = arguments[index]
        switch flag {
        case "--cases": casesPath = try value(after: flag); index += 2
        case "--output": output = try value(after: flag); index += 2
        case "--prompt-id": promptID = try value(after: flag); index += 2
        case "--runs":
            guard let parsed = Int(try value(after: flag)), parsed > 0 else {
                throw CollectorError.usage("--runs must be a positive integer")
            }
            runs = parsed; index += 2
        case "--limit":
            guard let parsed = Int(try value(after: flag)), parsed > 0 else {
                throw CollectorError.usage("--limit must be a positive integer")
            }
            limit = parsed; index += 2
        case "--case": caseIDs.insert(try value(after: flag)); index += 2
        case "--no-resume": resume = false; index += 1
        case "--require-model": requireModel = true; index += 1
        default: throw CollectorError.usage("Unknown argument: \(flag)\n\(usage())")
        }
    }
    guard let casesPath, let output, let promptID, !promptID.isEmpty else {
        throw CollectorError.usage(usage())
    }
    return Options(
        casesPath: casesPath, outputDirectory: output, promptID: promptID,
        runs: runs, limit: limit, caseIDs: caseIDs, resume: resume, requireModel: requireModel
    )
}

private func tierName(_ tier: PlannerTier) -> String {
    switch tier {
    case .privateCloud: "privateCloud"
    case .onDevice: "onDevice"
    case .ruleBased: "ruleBased"
    }
}

private func fallbackReason(_ tier: PlannerTier) -> String? {
    guard case let .ruleBased(reason) = tier else { return nil }
    guard let reason else { return "chosenDefault" }
    switch reason {
    case .deviceNotEligible: return "deviceNotEligible"
    case .appleIntelligenceNotEnabled: return "appleIntelligenceNotEnabled"
    case .modelNotReady: return "modelNotReady"
    case .offlineOrError: return "offlineOrError"
    case .quotaExhausted: return "quotaExhausted"
    }
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(value)
    data.append(0x0A)
    try data.write(to: url, options: .atomic)
}

@main
struct QueryCollectorMain {
    static func main() async {
        do {
            let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            let decoder = JSONDecoder()
            let corpusURL = URL(fileURLWithPath: options.casesPath)
            let corpus = try decoder.decode(ShoppingQueryCorpus.self, from: Data(contentsOf: corpusURL))
            let allIDs = Set(corpus.cases.map(\.id))
            let unsafeIDs = allIDs.filter {
                $0.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) == nil
            }
            guard unsafeIDs.isEmpty else {
                throw CollectorError.invalid(
                    "Case IDs must be lowercase filesystem-safe slugs: \(unsafeIDs.sorted().joined(separator: ", "))"
                )
            }
            let unknown = options.caseIDs.subtracting(allIDs)
            guard unknown.isEmpty else {
                throw CollectorError.invalid("Unknown case IDs: \(unknown.sorted().joined(separator: ", "))")
            }

            var selected = options.caseIDs.isEmpty
                ? corpus.cases
                : corpus.cases.filter { options.caseIDs.contains($0.id) }
            if let limit = options.limit { selected = Array(selected.prefix(limit)) }
            guard !selected.isEmpty else { throw CollectorError.invalid("No cases selected") }
            let selectedIDs = Set(selected.map(\.id))
            let requestedRuns = Set((1...options.runs).map { "run-\($0)" })

            let outputURL = URL(fileURLWithPath: options.outputDirectory, isDirectory: true)
            let rawURL = outputURL.appendingPathComponent("raw", isDirectory: true)
            try FileManager.default.createDirectory(at: rawURL, withIntermediateDirectories: true)
            let observationsURL = outputURL.appendingPathComponent("observations.json")

            var observations: [QueryPlanningObservation] = []
            if options.resume, FileManager.default.fileExists(atPath: observationsURL.path) {
                let existing = try decoder.decode(
                    QueryPlanningObservationFile.self,
                    from: Data(contentsOf: observationsURL)
                )
                guard existing.promptID == options.promptID else {
                    throw CollectorError.invalid(
                        "Existing observations use promptID \(existing.promptID), not \(options.promptID); use --no-resume or a different output directory"
                    )
                }
                observations = existing.runs.filter {
                    selectedIDs.contains($0.caseID) && requestedRuns.contains($0.runID)
                }
            }
            var completed = Set(observations.map { $0.caseID + "\u{1f}" + $0.runID })
            let planner = AppleFoundationMissionPlanner()

            for testCase in selected {
                let profile = testCase.tasteProfile?.resolved() ?? SeedData.defaultTasteProfile
                for runNumber in 1...options.runs {
                    let runID = "run-\(runNumber)"
                    let key = testCase.id + "\u{1f}" + runID
                    if completed.contains(key) {
                        print("skip \(testCase.id)/\(runID) (already recorded)")
                        continue
                    }
                    print("run  \(testCase.id)/\(runID)")
                    let startedAt = Date()
                    let planned = await planner.plan(goal: testCase.goal, profile: profile)
                    let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
                    let observation = QueryPlanningObservation(
                        caseID: testCase.id,
                        runID: runID,
                        isShoppable: planned.isShoppable,
                        isSingleItem: planned.task?.isSingleItem,
                        queries: planned.task?.searchQueries ?? [],
                        plannerTier: tierName(planned.tier),
                        fallbackReason: fallbackReason(planned.tier)
                    )
                    observations.append(observation)
                    completed.insert(key)

                    let raw = RawPlannerRun(
                        caseID: testCase.id, runID: runID, goal: testCase.goal,
                        startedAt: startedAt, elapsedMilliseconds: elapsed,
                        tier: tierName(planned.tier), fallbackNote: planned.tier.fallbackNote,
                        isShoppable: planned.isShoppable,
                        isSingleItem: planned.task?.isSingleItem,
                        title: planned.task?.title, subtitle: planned.task?.subtitle,
                        plan: planned.task?.plan ?? [], queries: planned.task?.searchQueries ?? [],
                        decline: planned.decline, tasteProfile: profile
                    )
                    try writeJSON(raw, to: rawURL.appendingPathComponent("\(testCase.id)--\(runID).json"))
                    try writeJSON(
                        QueryPlanningObservationFile(promptID: options.promptID, runs: observations),
                        to: observationsURL
                    )
                    print("     \(tierName(planned.tier)) \(elapsed)ms queries=\(observation.queries)")
                }
            }
            // Always rewrite the current selection view, even when every requested run was resumed.
            // This prevents stale cases or a previous larger run count from entering the score.
            try writeJSON(
                QueryPlanningObservationFile(promptID: options.promptID, runs: observations),
                to: observationsURL
            )
            print("wrote \(observations.count) observations to \(observationsURL.path)")
            if options.requireModel {
                let degraded = observations.filter {
                    selectedIDs.contains($0.caseID)
                        && requestedRuns.contains($0.runID)
                        && $0.plannerTier != "onDevice"
                        && $0.plannerTier != "privateCloud"
                }
                guard degraded.isEmpty else {
                    let summary = degraded.map {
                        "\($0.caseID)/\($0.runID)=\($0.plannerTier ?? "unknown")"
                    }.joined(separator: ", ")
                    throw CollectorError.invalid(
                        "Foundation Models required, but these persisted runs degraded: \(summary)"
                    )
                }
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(2)
        }
    }
}
