import Foundation
import SwiftUI
import TrameProtocol

/// An Anthropic identity (spec F9). Each extra account gets its own
/// CLAUDE_CONFIG_DIR so logins, settings and transcripts are fully isolated.
/// The built-in "Default" account uses the standard ~/.claude.
struct Account: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var colorIndex: Int
}

nonisolated enum AccountStore {
    static let defaultAccountID = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!

    static let palette: [Color] = [.purple, .blue, .teal, .pink, .orange, .green, .indigo, .brown]

    static func color(for account: Account?) -> Color {
        guard let account else { return .secondary }
        return palette[account.colorIndex % palette.count]
    }

    private static var fileURL: URL {
        TramePaths.supportDirectory.appendingPathComponent("accounts.json")
    }

    /// Extra accounts only; the Default account is implicit.
    static func load() -> [Account] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    static func save(_ accounts: [Account]) {
        try? FileManager.default.createDirectory(at: TramePaths.supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(accounts) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Isolated Claude Code config dir for an account (spec F9.1).
    static func configDir(for accountID: UUID) -> String? {
        guard accountID != defaultAccountID else { return nil }
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".trame/accounts/\(accountID.uuidString.prefix(8).lowercased())")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
