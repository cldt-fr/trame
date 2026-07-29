import Foundation

/// A talkie-walkie message sent by a session, recovered from its Claude Code
/// transcript (MCP tool calls are recorded there — Trame is not in the
/// network path, but the sender's transcript sees every outgoing message).
public struct MeshMessage: Equatable, Sendable {
    public let timestamp: Date
    /// "send_message" or "broadcast_message".
    public let tool: String
    /// Target peer role for send_message; nil for broadcasts.
    public let to: String?
    public let text: String

    public init(timestamp: Date, tool: String, to: String?, text: String) {
        self.timestamp = timestamp
        self.tool = tool
        self.to = to
        self.text = text
    }

    public var isBroadcast: Bool {
        tool.contains("broadcast")
    }
}

public enum MeshMessageParser {
    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoParserNoFraction = ISO8601DateFormatter()

    /// Extracts talkie-walkie tool calls from one JSONL transcript line.
    public static func parseLine(_ line: Data) -> [MeshMessage] {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }

        let tsString = obj["timestamp"] as? String ?? ""
        let timestamp = isoParser.date(from: tsString)
            ?? isoParserNoFraction.date(from: tsString)
            ?? Date(timeIntervalSince1970: 0)

        var result: [MeshMessage] = []
        for block in content {
            guard block["type"] as? String == "tool_use",
                  let name = (block["name"] as? String)?.lowercased(),
                  name.contains("talkie"),
                  name.contains("message") else { continue }
            let input = block["input"] as? [String: Any] ?? [:]
            let to = (input["to"] as? String)
                ?? (input["recipient"] as? String)
                ?? (input["peer"] as? String)
                ?? (input["name"] as? String)
            let text = (input["message"] as? String)
                ?? (input["content"] as? String)
                ?? (input["text"] as? String)
                ?? ""
            let tool = name.contains("broadcast") ? "broadcast_message" : "send_message"
            result.append(MeshMessage(timestamp: timestamp, tool: tool, to: to, text: text))
        }
        return result
    }

    /// All mesh messages sent from a working directory's sessions.
    public static func scan(configDir: String, cwd: String, since: Date?) -> [MeshMessage] {
        let projectDir = (configDir as NSString)
            .appendingPathComponent("projects/\(UsageScanner.projectSlug(forCwd: cwd))")
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: projectDir) else { return [] }
        var messages: [MeshMessage] = []
        for file in files where file.hasSuffix(".jsonl") {
            let path = (projectDir as NSString).appendingPathComponent(file)
            if let since,
               let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               mtime < since {
                continue
            }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            for line in data.split(separator: 0x0A) {
                for msg in parseLine(Data(line)) {
                    if let since, msg.timestamp < since { continue }
                    messages.append(msg)
                }
            }
        }
        return messages.sorted { $0.timestamp < $1.timestamp }
    }
}
