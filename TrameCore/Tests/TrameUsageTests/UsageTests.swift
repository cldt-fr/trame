import Foundation
import Testing
@testable import TrameUsage

@Suite struct UsageTests {
    private let assistantLine = """
    {"type":"assistant","timestamp":"2026-07-29T10:00:00.000Z","sessionId":"abc","message":{"model":"claude-opus-5","usage":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":2000,"cache_read_input_tokens":10000}}}
    """

    @Test func parseAssistantLine() throws {
        let event = try #require(TranscriptParser.parseLine(Data(assistantLine.utf8)))
        #expect(event.model == "claude-opus-5")
        #expect(event.inputTokens == 1000)
        #expect(event.outputTokens == 500)
        #expect(event.cacheCreationTokens == 2000)
        #expect(event.cacheReadTokens == 10000)
    }

    @Test func ignoresNonAssistantLines() {
        let user = #"{"type":"user","message":{"content":"hi"}}"#
        #expect(TranscriptParser.parseLine(Data(user.utf8)) == nil)
        #expect(TranscriptParser.parseLine(Data("not json".utf8)) == nil)
    }

    @Test func costMath() throws {
        let event = try #require(TranscriptParser.parseLine(Data(assistantLine.utf8)))
        // Opus 5: $5/M in, $25/M out; cache write 1.25×, cache read 0.1×.
        let expected = 1000 * 5.0 / 1e6
            + 2000 * 5.0 * 1.25 / 1e6
            + 10000 * 5.0 * 0.1 / 1e6
            + 500 * 25.0 / 1e6
        #expect(abs(event.costUSD - expected) < 1e-9)
    }

    @Test func pricingFamilies() {
        func cost(model: String) -> Double {
            UsageEvent(timestamp: Date(timeIntervalSince1970: 0), model: model,
                       inputTokens: 1_000_000, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0).costUSD
        }
        #expect(cost(model: "claude-fable-5") == 10)
        #expect(cost(model: "claude-opus-4-1-20250805") == 15)
        #expect(cost(model: "claude-opus-5") == 5)
        #expect(cost(model: "claude-sonnet-5") == 3)
        #expect(cost(model: "claude-haiku-4-5-20251001") == 1)
    }

    @Test func projectSlug() {
        #expect(UsageScanner.projectSlug(forCwd: "/Users/cldt/XCodeProjects/trame/Trame")
                == "-Users-cldt-XCodeProjects-trame-Trame")
        #expect(UsageScanner.projectSlug(forCwd: "/tmp/my_app.v2")
                == "-tmp-my-app-v2")
    }

    @Test func scanAndAggregate() throws {
        let dir = NSTemporaryDirectory() + "trame-usage-test-\(UUID().uuidString.prefix(8))"
        let projectDir = dir + "/projects/-tmp-demo"
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let lines = [
            assistantLine,
            #"{"type":"user","message":{"content":"hi"}}"#,
            """
            {"type":"assistant","timestamp":"2026-07-28T09:00:00.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
            """,
        ].joined(separator: "\n")
        try lines.write(toFile: projectDir + "/session1.jsonl", atomically: true, encoding: .utf8)

        let events = UsageScanner.scan(configDirs: [dir], since: nil)
        #expect(events.count == 2)

        let totals = UsageAggregator.totals(events)
        #expect(totals.messageCount == 2)
        #expect(totals.inputTokens == 1100)

        let days = UsageAggregator.byDay(events)
        #expect(days.count == 2)

        let models = UsageAggregator.byModel(events)
        #expect(models.first?.model == "claude-opus-5") // sorted by cost desc

        // Time filter drops the older event.
        let recent = UsageScanner.scan(
            configDirs: [dir],
            since: ISO8601DateFormatter().date(from: "2026-07-29T00:00:00Z")
        )
        // File mtime is now, so the file is scanned; the event filter applies.
        #expect(recent.count == 1)
        #expect(recent.first?.model == "claude-opus-5")
    }
}
