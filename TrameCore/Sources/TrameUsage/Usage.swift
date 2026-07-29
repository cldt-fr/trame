import Foundation

// MARK: - Model

/// One assistant message's token usage, parsed from a Claude Code transcript.
public struct UsageEvent: Equatable, Sendable {
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int

    public init(timestamp: Date, model: String, inputTokens: Int, outputTokens: Int,
                cacheCreationTokens: Int, cacheReadTokens: Int) {
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }

    public var costUSD: Double {
        Pricing.cost(for: self)
    }
}

public struct UsageTotals: Equatable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheCreationTokens = 0
    public var cacheReadTokens = 0
    public var costUSD = 0.0
    public var messageCount = 0

    public init() {}

    public mutating func add(_ event: UsageEvent) {
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        cacheCreationTokens += event.cacheCreationTokens
        cacheReadTokens += event.cacheReadTokens
        costUSD += event.costUSD
        messageCount += 1
    }
}

// MARK: - Pricing

/// USD per million tokens. Cache writes bill at 1.25× input, cache reads at
/// 0.1× input. Costs shown in Trame are estimates (spec F7.4).
public enum Pricing {
    struct Rate {
        let input: Double
        let output: Double
    }

    /// Longest-match wins; keep specific ids before generic family names.
    static let rates: [(pattern: String, rate: Rate)] = [
        ("fable-5", Rate(input: 10, output: 50)),
        ("mythos", Rate(input: 10, output: 50)),
        ("opus-4-1", Rate(input: 15, output: 75)),
        ("opus-4-0", Rate(input: 15, output: 75)),
        ("opus", Rate(input: 5, output: 25)),
        ("sonnet", Rate(input: 3, output: 15)),
        ("haiku-3-5", Rate(input: 0.8, output: 4)),
        ("haiku", Rate(input: 1, output: 5)),
    ]

    static func rate(for model: String) -> Rate {
        let lower = model.lowercased()
        for (pattern, rate) in rates where lower.contains(pattern) {
            return rate
        }
        return Rate(input: 5, output: 25)
    }

    public static func cost(for event: UsageEvent) -> Double {
        let r = rate(for: event.model)
        let perTokenIn = r.input / 1_000_000
        let perTokenOut = r.output / 1_000_000
        return Double(event.inputTokens) * perTokenIn
            + Double(event.cacheCreationTokens) * perTokenIn * 1.25
            + Double(event.cacheReadTokens) * perTokenIn * 0.1
            + Double(event.outputTokens) * perTokenOut
    }
}

// MARK: - Transcript parsing

public enum TranscriptParser {
    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoParserNoFraction = ISO8601DateFormatter()

    /// Parses one JSONL transcript line; returns nil for non-assistant lines
    /// or lines without usage.
    public static func parseLine(_ line: Data) -> UsageEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return nil }

        let tsString = obj["timestamp"] as? String ?? ""
        let timestamp = isoParser.date(from: tsString)
            ?? isoParserNoFraction.date(from: tsString)
            ?? Date(timeIntervalSince1970: 0)

        return UsageEvent(
            timestamp: timestamp,
            model: message["model"] as? String ?? "unknown",
            inputTokens: usage["input_tokens"] as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0,
            cacheCreationTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
            cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0
        )
    }

    public static func parseFile(at url: URL, since: Date? = nil) -> [UsageEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var events: [UsageEvent] = []
        for line in data.split(separator: 0x0A) {
            guard let event = parseLine(Data(line)) else { continue }
            if let since, event.timestamp < since { continue }
            events.append(event)
        }
        return events
    }
}

// MARK: - Scanning

/// Reads Claude Code transcripts from one or more config dirs
/// (`<configDir>/projects/<cwd-slug>/*.jsonl`).
public enum UsageScanner {
    /// Claude Code's project-directory slug for a working directory.
    public static func projectSlug(forCwd cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// All events across every project of every config dir, newest files
    /// filtered by modification date for cheap incremental scans.
    public static func scan(configDirs: [String], since: Date?) -> [UsageEvent] {
        var events: [UsageEvent] = []
        let fm = FileManager.default
        for dir in configDirs {
            let projects = (dir as NSString).appendingPathComponent("projects")
            guard let names = try? fm.contentsOfDirectory(atPath: projects) else { continue }
            for name in names {
                let projectDir = (projects as NSString).appendingPathComponent(name)
                events.append(contentsOf: scanProjectDir(projectDir, since: since))
            }
        }
        return events
    }

    /// Events for one working directory inside one config dir.
    public static func scan(configDir: String, cwd: String, since: Date?) -> [UsageEvent] {
        let projectDir = (configDir as NSString)
            .appendingPathComponent("projects/\(projectSlug(forCwd: cwd))")
        return scanProjectDir(projectDir, since: since)
    }

    private static func scanProjectDir(_ projectDir: String, since: Date?) -> [UsageEvent] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: projectDir) else { return [] }
        var events: [UsageEvent] = []
        for file in files where file.hasSuffix(".jsonl") {
            let path = (projectDir as NSString).appendingPathComponent(file)
            if let since,
               let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               mtime < since {
                continue
            }
            events.append(contentsOf: TranscriptParser.parseFile(at: URL(fileURLWithPath: path), since: since))
        }
        return events
    }
}

// MARK: - Aggregation

public enum UsageAggregator {
    public static func totals(_ events: [UsageEvent]) -> UsageTotals {
        var t = UsageTotals()
        for e in events { t.add(e) }
        return t
    }

    /// Totals per calendar day (start-of-day dates), for the daily bar chart.
    public static func byDay(_ events: [UsageEvent], calendar: Calendar = .current) -> [(day: Date, totals: UsageTotals)] {
        var buckets: [Date: UsageTotals] = [:]
        for e in events {
            let day = calendar.startOfDay(for: e.timestamp)
            buckets[day, default: UsageTotals()].add(e)
        }
        return buckets.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    public static func byModel(_ events: [UsageEvent]) -> [(model: String, totals: UsageTotals)] {
        var buckets: [String: UsageTotals] = [:]
        for e in events {
            buckets[e.model, default: UsageTotals()].add(e)
        }
        return buckets.sorted { $0.value.costUSD > $1.value.costUSD }.map { ($0.key, $0.value) }
    }
}
