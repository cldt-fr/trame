import Foundation
import TrameMCP
import TrameProtocol

/// A session participating in the talkie-walkie mesh (F4.1).
struct MeshMember: Codable, Identifiable, Hashable {
    /// Trame session id.
    var id: String
    var role: String
    var port: Int
    /// Roles this session knew at launch; a mismatch with the current mesh
    /// means the session must be restarted to see new peers (F4.6).
    var peerRolesAtLaunch: [String]
}

/// A talkie-walkie instance running outside Trame (another machine, F4.4).
/// It must share the mesh secret and be reachable at host:port.
struct RemotePeer: Codable, Identifiable, Hashable {
    var id: UUID
    var role: String
    var host: String
    var port: Int

    init(id: UUID = UUID(), role: String, host: String, port: Int) {
        self.id = id
        self.role = role
        self.host = host
        self.port = port
    }
}

nonisolated enum MeshStore {
    /// Fixed identity for the talkie-walkie MCP entry so the shared secret
    /// rides the same Keychain + env-indirection path as any MCP secret.
    static let serverID = UUID(uuidString: "7714A100-0000-4000-8000-00000000AAAA")!
    static let basePort = 8788

    private static var fileURL: URL {
        TramePaths.supportDirectory.appendingPathComponent("mesh.json")
    }

    static func load() -> [MeshMember] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([MeshMember].self, from: data)) ?? []
    }

    static func save(_ members: [MeshMember]) {
        try? FileManager.default.createDirectory(at: TramePaths.supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(members) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static var remoteFileURL: URL {
        TramePaths.supportDirectory.appendingPathComponent("mesh-remote.json")
    }

    static func loadRemote() -> [RemotePeer] {
        guard let data = try? Data(contentsOf: remoteFileURL) else { return [] }
        return (try? JSONDecoder().decode([RemotePeer].self, from: data)) ?? []
    }

    static func saveRemote(_ peers: [RemotePeer]) {
        try? FileManager.default.createDirectory(at: TramePaths.supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(peers) {
            try? data.write(to: remoteFileURL, options: .atomic)
        }
    }

    /// The shared mesh secret (for configuring a remote machine).
    static func secret() -> String? {
        KeychainStore.get(account: MCPStore.secretAccount(serverID: serverID, key: "INTERCOM_SECRET"))
    }

    /// Shared mesh secret, generated once and kept in the Keychain.
    static func ensureSecret() {
        let account = MCPStore.secretAccount(serverID: serverID, key: "INTERCOM_SECRET")
        if KeychainStore.get(account: account) == nil {
            KeychainStore.set(UUID().uuidString, account: account)
        }
    }

    static func nextFreePort(members: [MeshMember]) -> Int {
        let used = Set(members.map(\.port))
        var port = basePort
        while used.contains(port) { port += 1 }
        return port
    }

    /// Unique role slug: lowercased, spaces → dashes, suffixed on collision.
    static func uniqueRole(from raw: String, members: [MeshMember]) -> String {
        let base = raw.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let slug = base.isEmpty ? "agent" : base
        let existing = Set(members.map(\.role))
        if !existing.contains(slug) { return slug }
        var n = 2
        while existing.contains("\(slug)-\(n)") { n += 1 }
        return "\(slug)-\(n)"
    }

    /// PEERS wire value for the given topology (local members + remote peers).
    static func peersValue(members: [MeshMember], remote: [RemotePeer]) -> String {
        (members.map { "\($0.role)=127.0.0.1:\($0.port)" }
         + remote.map { "\($0.role)=\($0.host):\($0.port)" })
            .joined(separator: ",")
    }

    /// The talkie-walkie MCP server entry for a new member, wired to the
    /// current mesh topology.
    static func talkieServer(role: String, port: Int, peers: [MeshMember], remote: [RemotePeer]) -> MCPServer {
        ensureSecret()
        let peersValue = peersValue(members: peers, remote: remote)
        return MCPServer(
            id: serverID,
            name: "talkie-walkie",
            transport: .stdio,
            commandLine: "npx -y claude-talkie-walkie",
            env: [
                MCPEnvVar(key: "MY_ROLE", value: role, isSecret: false),
                MCPEnvVar(key: "PEERS", value: peersValue, isSecret: false),
                MCPEnvVar(key: "INTERCOM_PORT", value: String(port), isSecret: false),
                MCPEnvVar(key: "INTERCOM_SECRET", value: "", isSecret: true),
            ]
        )
    }

    /// Flag required by talkie-walkie to expose its channels to the session.
    static let claudeFlag = "--dangerously-load-development-channels server:talkie-walkie"
}
