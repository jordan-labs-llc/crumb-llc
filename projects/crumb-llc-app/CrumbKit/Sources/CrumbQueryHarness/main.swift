import CrumbKit
import Foundation

enum CLIError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self { case let .usage(message): message }
    }
}

func usage() -> String {
    "Usage: crumb-query-harness --cases PATH --observations PATH [--format text|json] [--allow-partial]"
}

func parseArguments(_ arguments: [String]) throws -> (cases: String, observations: String, format: String, allowPartial: Bool) {
    if arguments.contains("--help") || arguments.contains("-h") {
        print(usage())
        exit(0)
    }
    var values: [String: String] = [:]
    var allowPartial = false
    var index = 0
    while index < arguments.count {
        let key = arguments[index]
        if key == "--allow-partial" {
            allowPartial = true
            index += 1
            continue
        }
        guard ["--cases", "--observations", "--format"].contains(key), index + 1 < arguments.count else {
            throw CLIError.usage("Unknown or incomplete argument: \(key)\n\(usage())")
        }
        values[key] = arguments[index + 1]
        index += 2
    }
    guard let cases = values["--cases"], let observations = values["--observations"] else {
        throw CLIError.usage(usage())
    }
    let format = values["--format"] ?? "text"
    guard format == "text" || format == "json" else {
        throw CLIError.usage("--format must be text or json")
    }
    return (cases, observations, format, allowPartial)
}

do {
    let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    let decoder = JSONDecoder()
    let corpus = try decoder.decode(ShoppingQueryCorpus.self, from: Data(contentsOf: URL(fileURLWithPath: options.cases)))
    let observations = try decoder.decode(QueryPlanningObservationFile.self, from: Data(contentsOf: URL(fileURLWithPath: options.observations)))
    let report = try QueryHillClimbScorer.report(
        corpus: corpus, observations: observations, allowPartial: options.allowPartial
    )
    if options.format == "json" {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
        print(QueryHillClimbScorer.textReport(report), terminator: "")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(2)
}
