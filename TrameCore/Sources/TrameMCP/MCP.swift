import Foundation

// MARK: - Models

public enum MCPTransport: String, Codable, CaseIterable, Sendable {
    case stdio
    case http
    case sse
}

public struct MCPEnvVar: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var key: String
    /// Plain value; empty for secrets (the real value lives in the Keychain,
    /// resolved at session launch through the injected resolver).
    public var value: String
    public var isSecret: Bool

    public init(id: UUID = UUID(), key: String, value: String, isSecret: Bool) {
        self.id = id
        self.key = key
        self.value = value
        self.isSecret = isSecret
    }
}

public struct MCPServer: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var transport: MCPTransport
    /// Full command line for stdio servers (whitespace-separated).
    public var commandLine: String
    /// Endpoint for http/sse servers.
    public var url: String
    public var env: [MCPEnvVar]

    public init(id: UUID = UUID(), name: String, transport: MCPTransport,
                commandLine: String = "", url: String = "", env: [MCPEnvVar] = []) {
        self.id = id
        self.name = name
        self.transport = transport
        self.commandLine = commandLine
        self.url = url
        self.env = env
    }
}

public struct MCPProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var serverIDs: [UUID]

    public init(id: UUID = UUID(), name: String, serverIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.serverIDs = serverIDs
    }
}

// MARK: - Config generation

public struct MCPLaunchConfig: Sendable {
    /// JSON for `claude --mcp-config <file>`.
    public let configJSON: Data
    /// Environment to inject into the session; referenced from the config via
    /// `${VAR}` so secrets never land on disk.
    public let sessionEnv: [String: String]
}

public enum MCPConfigBuilder {
    /// Builds the launch config for a set of servers. `secretResolver` maps
    /// (server, key) to the secret value (from the Keychain on the app side).
    public static func build(
        servers: [MCPServer],
        secretResolver: (MCPServer, String) -> String?
    ) throws -> MCPLaunchConfig {
        var mcpServers: [String: Any] = [:]
        var sessionEnv: [String: String] = [:]

        for server in servers {
            var entry: [String: Any] = [:]
            switch server.transport {
            case .stdio:
                let parts = server.commandLine
                    .split(separator: " ", omittingEmptySubsequences: true)
                    .map(String.init)
                guard let command = parts.first else { continue }
                entry["command"] = command
                if parts.count > 1 {
                    entry["args"] = Array(parts.dropFirst())
                }
            case .http, .sse:
                entry["type"] = server.transport.rawValue
                entry["url"] = server.url
            }

            if !server.env.isEmpty {
                var envDict: [String: String] = [:]
                for envVar in server.env where !envVar.key.isEmpty {
                    if envVar.isSecret {
                        let indirect = indirectName(server: server, key: envVar.key)
                        envDict[envVar.key] = "${\(indirect)}"
                        if let secret = secretResolver(server, envVar.key) {
                            sessionEnv[indirect] = secret
                        }
                    } else {
                        envDict[envVar.key] = envVar.value
                    }
                }
                if !envDict.isEmpty {
                    entry["env"] = envDict
                }
            }
            mcpServers[server.name] = entry
        }

        let json = try JSONSerialization.data(
            withJSONObject: ["mcpServers": mcpServers],
            options: [.prettyPrinted, .sortedKeys]
        )
        return MCPLaunchConfig(configJSON: json, sessionEnv: sessionEnv)
    }

    /// Env-var name carrying a secret into the session, e.g.
    /// TRAME_MCP_POSTGRES_DATABASE_URL.
    public static func indirectName(server: MCPServer, key: String) -> String {
        let sanitized = server.name.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return "TRAME_MCP_\(String(sanitized))_\(key)"
    }
}
