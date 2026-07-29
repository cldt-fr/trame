import Foundation
import Testing
@testable import TrameMCP

@Suite struct MCPConfigTests {
    @Test func stdioServerWithSecret() throws {
        let server = MCPServer(
            name: "postgres",
            transport: .stdio,
            commandLine: "npx -y @modelcontextprotocol/server-postgres",
            env: [
                MCPEnvVar(key: "DATABASE_URL", value: "", isSecret: true),
                MCPEnvVar(key: "PGAPPNAME", value: "trame", isSecret: false),
            ]
        )
        let config = try MCPConfigBuilder.build(servers: [server]) { _, key in
            key == "DATABASE_URL" ? "postgres://secret" : nil
        }

        let root = try JSONSerialization.jsonObject(with: config.configJSON) as! [String: Any]
        let entry = (root["mcpServers"] as! [String: Any])["postgres"] as! [String: Any]
        #expect(entry["command"] as? String == "npx")
        #expect(entry["args"] as? [String] == ["-y", "@modelcontextprotocol/server-postgres"])

        let env = entry["env"] as! [String: String]
        // The secret never appears in the JSON, only an env-var reference.
        #expect(env["DATABASE_URL"] == "${TRAME_MCP_POSTGRES_DATABASE_URL}")
        #expect(env["PGAPPNAME"] == "trame")
        #expect(!String(decoding: config.configJSON, as: UTF8.self).contains("postgres://secret"))
        // The real value rides along in the session environment.
        #expect(config.sessionEnv["TRAME_MCP_POSTGRES_DATABASE_URL"] == "postgres://secret")
    }

    @Test func httpServer() throws {
        let server = MCPServer(name: "context7", transport: .http, url: "https://mcp.context7.com/mcp")
        let config = try MCPConfigBuilder.build(servers: [server]) { _, _ in nil }
        let root = try JSONSerialization.jsonObject(with: config.configJSON) as! [String: Any]
        let entry = (root["mcpServers"] as! [String: Any])["context7"] as! [String: Any]
        #expect(entry["type"] as? String == "http")
        #expect(entry["url"] as? String == "https://mcp.context7.com/mcp")
        #expect(config.sessionEnv.isEmpty)
    }

    @Test func indirectNameSanitized() {
        let server = MCPServer(name: "my-server 2", transport: .stdio)
        #expect(MCPConfigBuilder.indirectName(server: server, key: "TOKEN") == "TRAME_MCP_MY_SERVER_2_TOKEN")
    }
}
