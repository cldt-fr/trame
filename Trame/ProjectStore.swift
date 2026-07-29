import Foundation
import TrameProtocol

struct Project: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    let root: String
    /// F1.9 light : dernière commande utilisée, ré-appliquée par défaut.
    var lastCommand: String?
    /// Derniers serveurs MCP attachés, ré-appliqués par défaut (F1.9/F3).
    var lastMCPServerIDs: [UUID]?
    /// Dernier preset de permissions utilisé (F8).
    var lastPermissionPreset: String?
}

enum ProjectStore {
    private static var fileURL: URL {
        TramePaths.supportDirectory.appendingPathComponent("projects.json")
    }

    static func load() -> [Project] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Project].self, from: data)) ?? []
    }

    static func save(_ projects: [Project]) {
        try? FileManager.default.createDirectory(at: TramePaths.supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(projects) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

enum WorktreeLayout {
    /// Spec F1.2 : les worktrees gérés par Trame vivent sous ~/.trame/worktrees/<projet>/<branche>.
    static var base: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".trame/worktrees")
    }

    static func directory(for project: Project) -> String {
        (base as NSString).appendingPathComponent(project.name)
    }

    static func path(for project: Project, branch: String) -> String {
        let slug = branch.replacingOccurrences(of: "/", with: "-")
        return (directory(for: project) as NSString).appendingPathComponent(slug)
    }

    static func isManagedWorktree(_ path: String) -> Bool {
        path.hasPrefix(base + "/")
    }
}
