import Foundation
import TrameProtocol

/// A reusable session role (V2): command, permissions, mesh identity and a
/// pre-written mission injected when the session starts.
struct SessionTemplate: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var command: String
    var preset: String
    var meshEnabled: Bool
    var meshRole: String
    var mission: String

    init(id: UUID = UUID(), name: String, command: String = "claude", preset: String = "prudent",
         meshEnabled: Bool = false, meshRole: String = "", mission: String = "") {
        self.id = id
        self.name = name
        self.command = command
        self.preset = preset
        self.meshEnabled = meshEnabled
        self.meshRole = meshRole
        self.mission = mission
    }
}

nonisolated enum TemplateStore {
    private static var fileURL: URL {
        TramePaths.supportDirectory.appendingPathComponent("templates.json")
    }

    /// Starter roles seeded on first launch — freely editable/deletable.
    static let defaults: [SessionTemplate] = [
        SessionTemplate(
            name: "Dev",
            preset: "standard",
            meshEnabled: true,
            meshRole: "dev",
            mission: "Implement the objective below. When you are done, use talkie-walkie to ask the reviewer to check your changes, and address their feedback. Objective: "
        ),
        SessionTemplate(
            name: "Reviewer",
            preset: "standard",
            meshEnabled: true,
            meshRole: "reviewer",
            mission: "You are the code reviewer of this agent team. Use talkie-walkie: list your peers, then wait for review requests. When one arrives, review the changes thoroughly (correctness, tests, style) and reply to the requester with your findings."
        ),
        SessionTemplate(
            name: "Tester",
            preset: "standard",
            meshEnabled: true,
            meshRole: "tester",
            mission: "You are the test runner of this agent team. Use talkie-walkie: list your peers, then wait for requests. When an agent asks, run the relevant tests and report the results (including failures verbatim) back to them."
        ),
    ]

    static func load() -> [SessionTemplate] {
        guard let data = try? Data(contentsOf: fileURL) else {
            save(defaults)
            return defaults
        }
        return (try? JSONDecoder().decode([SessionTemplate].self, from: data)) ?? defaults
    }

    static func save(_ templates: [SessionTemplate]) {
        try? FileManager.default.createDirectory(at: TramePaths.supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(templates) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
