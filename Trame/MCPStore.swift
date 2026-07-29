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

    /// Rewrites the PEERS value inside an existing launch config and resolves
    /// every `${VAR}` secret reference back from the Keychain, so a mesh
    /// session can be restarted with the current topology (F4.6 workaround).
    static func updatePeersAndResolveEnv(configPath: String, peers: String,
                                         servers: [MCPServer]) -> [String: String]? {
        guard let data = FileManager.default.contents(atPath: configPath),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var mcpServers = root["mcpServers"] as? [String: Any] else { return nil }

        if var talkie = mcpServers["talkie-walkie"] as? [String: Any],
           var env = talkie["env"] as? [String: String] {
            env["PEERS"] = peers
            talkie["env"] = env
            mcpServers["talkie-walkie"] = talkie
            root["mcpServers"] = mcpServers
            guard let updated = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
                  (try? updated.write(to: URL(fileURLWithPath: configPath), options: .atomic)) != nil else {
                return nil
            }
        }
        return resolveEnv(mcpServers: mcpServers, servers: servers)
    }

    /// Rebuilds the session environment for an existing launch config by
    /// resolving its `${VAR}` secret references from the Keychain — used when
    /// restarting a session.
    static func resolveEnv(configPath: String, servers: [MCPServer]) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: configPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcpServers = root["mcpServers"] as? [String: Any] else { return [:] }
        return resolveEnv(mcpServers: mcpServers, servers: servers)
    }

    private static func resolveEnv(mcpServers: [String: Any], servers: [MCPServer]) -> [String: String] {
        var sessionEnv: [String: String] = [:]
        for (name, entryAny) in mcpServers {
            guard let entry = entryAny as? [String: Any],
                  let env = entry["env"] as? [String: String] else { continue }
            let serverID: UUID? = name == "talkie-walkie"
                ? MeshStore.serverID
                : servers.first { $0.name == name }?.id
            for (key, value) in env where value.hasPrefix("${") && value.hasSuffix("}") {
                let varName = String(value.dropFirst(2).dropLast(1))
                if let serverID,
                   let secret = KeychainStore.get(account: secretAccount(serverID: serverID, key: key)) {
                    sessionEnv[varName] = secret
                }
            }
        }
        return sessionEnv
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
