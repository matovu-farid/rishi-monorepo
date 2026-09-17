import Foundation

public struct MemorySnapshot: MemorySnapshotting, Sendable {
    typealias RunProcess = @Sendable (String, [String], [String: String], Duration) async throws -> CommandResult

    private let runProcess: RunProcess
    private let environment: [String: String]

    public init(runner: ProcessRunner = ProcessRunner(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.runProcess = { executable, arguments, environment, timeout in
            try await runner.run(executable, arguments: arguments, environment: environment, timeout: timeout)
        }
        self.environment = environment
    }

    init(environment: [String: String], run: @escaping RunProcess) {
        self.runProcess = run
        self.environment = environment
    }

    public func snapshot(match: String) async throws -> JSONValue {
        let processMatch = ["catalyst", "iphone17"].contains(match.lowercased()) ? "rishi.app" : match
        async let vm = runProcess("/usr/bin/env", ["vm_stat"], environment, .seconds(3))
        async let hostRSS = runProcess(
            "/usr/bin/env",
            ["ps", "-p", String(ProcessInfo.processInfo.processIdentifier), "-o", "rss="],
            environment,
            .seconds(3)
        )
        async let processList: CommandResult? = processMatch.isEmpty
            ? nil
            : try await runProcess("/usr/bin/env", ["ps", "-axo", "pid=,rss=,command="], environment, .seconds(3))
        let vmResult = try await vm
        let hostRSSResult = try await hostRSS
        let processListResult = try await processList
        let pageSize: Int
        if let regex = try? NSRegularExpression(pattern: #"page size of (\d+) bytes"#),
           let match = regex.firstMatch(in: vmResult.stdout, range: NSRange(vmResult.stdout.startIndex..., in: vmResult.stdout)),
           let range = Range(match.range(at: 1), in: vmResult.stdout),
           let value = Int(vmResult.stdout[range]) {
            pageSize = value
        } else {
            pageSize = 4096
        }
        var pages: [String: JSONValue] = [:]
        for (key, value) in Self.parsePageCounters(from: vmResult.stdout) {
            pages[key] = .integer(value)
        }
        let processOutput = processListResult?.stdout ?? ""
        let processes = processOutput.split(separator: "\n").compactMap { line -> JSONValue? in
            let value = String(line).trimmingCharacters(in: .whitespaces); guard !value.isEmpty, processMatch.isEmpty || value.localizedCaseInsensitiveContains(processMatch) else { return nil }
            let parts = value.split(separator: " ", maxSplits: 2); guard parts.count == 3, let pid = Int(parts[0]), let rss = Int(parts[1]) else { return nil }
            return .object(["pid": .integer(pid), "rssKb": .integer(rss), "command": .string(String(parts[2]))])
        }
        let processRSSKb = Self.parseProcessRSSKb(from: hostRSSResult.stdout) ?? 0
        let availablePages = ["pages_free", "pages_inactive", "pages_speculative"]
            .compactMap { Self.parsePageCounters(from: vmResult.stdout)[$0] }
            .reduce(0, +)
        let availableMemoryBytes = availablePages * pageSize
        return .object([
            "host": .object([
                "pageSize": .integer(pageSize),
                "pages": .object(pages),
                "processRssKb": .integer(processRSSKb),
                "availableMemoryBytes": .integer(availableMemoryBytes),
            ]),
            "matchingProcesses": .array(processes),
        ])
    }

    static func parsePageCounters(from output: String) -> [String: Int] {
        output.split(separator: "\n").reduce(into: [:]) { result, line in
            guard line.hasPrefix("Pages ") else { return }
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { return }
            let digits = pieces[1].filter(\.isNumber)
            guard let value = Int(digits) else { return }
            result[String(pieces[0]).lowercased().replacingOccurrences(of: " ", with: "_")] = value
        }
    }

    static func parseProcessRSSKb(from output: String) -> Int? {
        output.split(whereSeparator: \.isNewline)
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .first
    }
}
