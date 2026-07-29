import Foundation
import Security
import TrameMCP
import TrameProtocol

/// Generic-password Keychain storage for MCP secrets (spec F3.2).
nonisolated enum KeychainStore {
    private static let service = "fr.cldt.Trame"

    static func set(_ value: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

nonisolated enum MCPStore {
    struct LibraryFile: Codable {
        var servers: [MCPServer]
        var profiles: [MCPProfile]
    }

    private static var fileURL: URL {
        TramePaths.supportDirectory.appendingPathComponent("mcp-library.json")
    }

    static func load() -> (servers: [MCPServer], profiles: [MCPProfile]) {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(LibraryFile.self, from: data) else {
            return ([], [])
        }
        return (file.servers, file.profiles)
    }

    static func save(servers: [MCPServer], profiles: [MCPProfile]) {
        try? FileManager.default.createDirectory(at: TramePaths.supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(LibraryFile(servers: servers, profiles: profiles)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func secretAccount(serverID: UUID, key: String) -> String {
        "mcp.\(serverID.uuidString).\(key)"
    }

    /// Builds the launch config for the selected servers, resolving secrets
    /// from the Keychain, and writes it under Application Support (never in
    /// the user's repo). Returns nil when no server is selected.
    static func writeLaunchConfig(servers: [MCPServer]) -> (configPath: String, env: [String: String])? {
        guard !servers.isEmpty else { return nil }
        guard let config = try? MCPConfigBuilder.build(servers: servers, secretResolver: { server, key in
            KeychainStore.get(account: secretAccount(serverID: server.id, key: key))
        }) else { return nil }

        let dir = TramePaths.supportDirectory.appendingPathComponent("mcp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("session-\(UUID().uuidString.prefix(8)).json")
        guard (try? config.configJSON.write(to: path, options: .atomic)) != nil else { return nil }
        return (path.path, config.sessionEnv)
    }
}
