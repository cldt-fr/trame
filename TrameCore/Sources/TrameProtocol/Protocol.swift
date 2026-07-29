import Foundation

// MARK: - Model

public struct SessionInfo: Codable, Identifiable, Hashable, Sendable {
    public enum State: Codable, Hashable, Sendable {
        case running
        case exited(code: Int32)
    }

    public let id: String
    public var name: String
    public let cwd: String
    public let command: [String]
    public var state: State
    public let createdAt: Date
    /// Why the session needs the user (from Claude Code hooks):
    /// "permission" while waiting for an approval/input, "done" when a turn
    /// ended. Cleared as soon as the user types into the session.
    public var attention: String?
    /// Human-readable detail attached to the attention state.
    public var attentionMessage: String?
    /// When the current attention state was raised.
    public var attentionAt: Date?

    public init(id: String, name: String, cwd: String, command: [String], state: State, createdAt: Date,
                attention: String? = nil, attentionMessage: String? = nil, attentionAt: Date? = nil) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.command = command
        self.state = state
        self.createdAt = createdAt
        self.attention = attention
        self.attentionMessage = attentionMessage
        self.attentionAt = attentionAt
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }
}

public struct DaemonInfo: Codable, Sendable {
    public let version: String
    public let pid: Int32

    public init(version: String, pid: Int32) {
        self.version = version
        self.pid = pid
    }
}

// MARK: - Control channel (newline-delimited JSON)

public enum DaemonRequest: Codable, Sendable {
    case daemonInfo
    case listSessions
    case createSession(name: String?, cwd: String, command: [String], env: [String: String], cols: UInt16, rows: UInt16)
    case renameSession(id: String, name: String)
    case resize(id: String, cols: UInt16, rows: UInt16)
    /// Dismisses the attention flag without touching the session.
    case clearAttention(id: String)
    /// SIGTERM the process; the session sticks around in `exited` state.
    case stopSession(id: String)
    /// SIGKILL the process if needed, then drop the session and its scrollback.
    case removeSession(id: String)
    case shutdown
}

public enum DaemonResponse: Codable, Sendable {
    case ok
    case info(DaemonInfo)
    case sessions([SessionInfo])
    case session(SessionInfo)
    case error(String)
}

public enum DaemonEvent: Codable, Sendable {
    /// Session list or a session state changed; clients should re-list.
    case sessionsChanged
}

public struct RequestLine: Codable, Sendable {
    public let id: Int
    public let req: DaemonRequest

    public init(id: Int, req: DaemonRequest) {
        self.id = id
        self.req = req
    }
}

/// Server→client line: either a response correlated by `id`, or an event (`id == 0`).
public struct ServerLine: Codable, Sendable {
    public let id: Int
    public let resp: DaemonResponse?
    public let event: DaemonEvent?

    public init(id: Int, resp: DaemonResponse? = nil, event: DaemonEvent? = nil) {
        self.id = id
        self.resp = resp
        self.event = event
    }
}

// MARK: - Hook channel

/// One-shot line sent by a Claude Code hook (fire and forget, connection
/// closed right after). `sessionID` comes from the TRAME_SESSION_ID env var
/// the daemon puts in every session it spawns.
public struct HookEventLine: Codable, Sendable {
    public let hookEvent: HookEvent

    public init(hookEvent: HookEvent) {
        self.hookEvent = hookEvent
    }
}

public struct HookEvent: Codable, Sendable {
    public let sessionID: String
    /// Claude Code hook name: "Notification", "Stop", …
    public let event: String
    public let message: String?

    public init(sessionID: String, event: String, message: String?) {
        self.sessionID = sessionID
        self.event = event
        self.message = message
    }
}

// MARK: - Attach channel

/// First line sent by the client on an attach connection; everything after the
/// server's `AttachReply` line is raw PTY bytes in both directions.
public struct AttachRequest: Codable, Sendable {
    public let attach: String
    public let replay: Bool

    public init(attach: String, replay: Bool) {
        self.attach = attach
        self.replay = replay
    }
}

public struct AttachReply: Codable, Sendable {
    public let ok: Bool
    public let error: String?

    public init(ok: Bool, error: String? = nil) {
        self.ok = ok
        self.error = error
    }
}

// MARK: - Paths

public enum TramePaths {
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trame", isDirectory: true)
    }

    /// Default daemon socket path; overridable for tests via TRAME_SOCKET.
    public static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["TRAME_SOCKET"], !override.isEmpty {
            return override
        }
        return supportDirectory.appendingPathComponent("daemon.sock").path
    }

    public static var logPath: String {
        supportDirectory.appendingPathComponent("daemon.log").path
    }
}

// MARK: - JSON helpers

public enum WireCodec {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}

/// Accumulates stream bytes and yields complete newline-terminated lines.
public final class LineBuffer {
    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let idx = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<idx))
            buffer.removeSubrange(buffer.startIndex...idx)
        }
        return lines
    }

    /// Bytes accumulated after the last newline (used when switching to raw mode).
    public func drainRemainder() -> Data {
        let rest = buffer
        buffer = Data()
        return rest
    }
}
