import CPTY
import Darwin
import Foundation
import TrameProtocol

public final class Daemon {
    public static let version = "0.3.0"

    private let socketPath: String
    private let queue = DispatchQueue(label: "trame.daemon.main")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var signalSources: [DispatchSourceSignal] = []

    private var sessions: [String: Session] = [:]
    private var connections: [ObjectIdentifier: ClientConnection] = [:]
    private var controlConnections: [ObjectIdentifier: ClientConnection] = [:]

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Binds the socket and serves forever. Exits the process when another
    /// daemon already owns the socket.
    public func run() -> Never {
        signal(SIGPIPE, SIG_IGN)

        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        DaemonLog.open(path: TramePaths.logPath)

        if Self.ping(socketPath: socketPath) {
            DaemonLog.log("daemon already running on \(socketPath), exiting")
            exit(0)
        }
        unlink(socketPath)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { fatalError("socket() failed: \(errno)") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        let copied = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cPath in
                strlcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cPath, pathCapacity)
            }
        }
        guard copied < pathCapacity else { fatalError("socket path too long: \(socketPath)") }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { fatalError("bind() failed: \(errno)") }
        guard listen(listenFD, 16) == 0 else { fatalError("listen() failed: \(errno)") }
        chmod(socketPath, 0o600)
        FDIO.setNonBlocking(listenFD)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        acceptSource = source
        source.resume()

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            s.setEventHandler { [weak self] in self?.performShutdown() }
            s.resume()
            signalSources.append(s)
        }

        DaemonLog.log("trame-core \(Self.version) listening on \(socketPath) (pid \(getpid()))")
        dispatchMain()
    }

    /// True when a live daemon answers on the socket.
    public static func ping(socketPath: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cPath in
                strlcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cPath, pathCapacity)
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            let conn = ClientConnection(fd: fd, daemon: self, daemonQueue: queue)
            connections[ObjectIdentifier(conn)] = conn
            conn.start()
        }
    }

    // MARK: - Connection registry (daemon queue)

    func register(control conn: ClientConnection) {
        controlConnections[ObjectIdentifier(conn)] = conn
    }

    func unregister(connection conn: ClientConnection) {
        connections.removeValue(forKey: ObjectIdentifier(conn))
        controlConnections.removeValue(forKey: ObjectIdentifier(conn))
    }

    private func broadcast(_ event: DaemonEvent) {
        let line = ServerLine(id: 0, event: event)
        for conn in controlConnections.values {
            conn.send(line)
        }
    }

    // MARK: - Requests (daemon queue)

    func handle(request: RequestLine, from conn: ClientConnection) {
        let resp = process(request.req)
        conn.send(ServerLine(id: request.id, resp: resp))
    }

    private func process(_ request: DaemonRequest) -> DaemonResponse {
        switch request {
        case .daemonInfo:
            return .info(DaemonInfo(version: Self.version, pid: getpid()))

        case .listSessions:
            let infos = sessions.values.map(\.info).sorted { $0.createdAt < $1.createdAt }
            return .sessions(infos)

        case let .createSession(name, cwd, command, env, cols, rows):
            return createSession(name: name, cwd: cwd, command: command, env: env, cols: cols, rows: rows)

        case let .renameSession(id, name):
            guard let session = sessions[id] else { return .error("unknown session \(id)") }
            session.rename(name)
            broadcast(.sessionsChanged)
            return .session(session.info)

        case let .resize(id, cols, rows):
            guard let session = sessions[id] else { return .error("unknown session \(id)") }
            session.resize(cols: cols, rows: rows)
            return .ok

        case let .clearAttention(id):
            guard let session = sessions[id] else { return .error("unknown session \(id)") }
            if session.setAttention(nil, message: nil) {
                broadcast(.sessionsChanged)
            }
            return .ok

        case let .stopSession(id):
            guard let session = sessions[id] else { return .error("unknown session \(id)") }
            session.signal(SIGTERM)
            return .ok

        case let .removeSession(id):
            guard let session = sessions.removeValue(forKey: id) else { return .error("unknown session \(id)") }
            session.destroy()
            broadcast(.sessionsChanged)
            return .ok

        case .shutdown:
            queue.async { self.performShutdown() }
            return .ok
        }
    }

    private func createSession(name: String?, cwd: String, command: [String], env: [String: String], cols: UInt16, rows: UInt16) -> DaemonResponse {
        guard !command.isEmpty else { return .error("empty command") }
        guard FileManager.default.fileExists(atPath: cwd) else { return .error("cwd does not exist: \(cwd)") }

        let id = String(UUID().uuidString.prefix(8)).lowercased()

        var childEnv = ProcessInfo.processInfo.environment
        childEnv["TERM"] = "xterm-256color"
        childEnv["COLORTERM"] = "truecolor"
        if childEnv["LANG"] == nil { childEnv["LANG"] = "en_US.UTF-8" }
        // Lets Claude Code hooks (child processes) report back to this session.
        childEnv["TRAME_SESSION_ID"] = id
        for (k, v) in env { childEnv[k] = v }
        let envStrings = childEnv.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        var masterFD: Int32 = -1
        let rc = withCStringArray(command) { argv in
            withCStringArray(envStrings) { envp in
                cpty_spawn(argv, envp, cwd, cols, rows, &pid, &masterFD)
            }
        }
        guard rc == 0 else { return .error("spawn failed: \(String(cString: strerror(rc)))") }

        let info = SessionInfo(
            id: id,
            name: name ?? autoName(cwd: cwd),
            cwd: cwd,
            command: command,
            state: .running,
            createdAt: Date()
        )
        let session = Session(info: info, masterFD: masterFD, pid: pid, queue: queue)
        session.onExit = { [weak self] _ in
            self?.broadcast(.sessionsChanged)
        }
        session.onUserInput = { [weak self, weak session] in
            guard let session else { return }
            if session.setAttention(nil, message: nil) {
                self?.broadcast(.sessionsChanged)
            }
        }
        sessions[id] = session
        session.startReading()
        DaemonLog.log("session \(id) '\(info.name)' spawned pid \(pid) in \(cwd)")
        broadcast(.sessionsChanged)
        return .session(info)
    }

    /// Auto-generated session names (spec F1.8): "<folder>-<n>".
    private func autoName(cwd: String) -> String {
        let base = (cwd as NSString).lastPathComponent.lowercased()
        let existing = Set(sessions.values.map(\.info.name))
        var n = 1
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    // MARK: - Attach (daemon queue)

    func handle(attach: AttachRequest, from conn: ClientConnection) {
        guard let session = sessions[attach.attach] else {
            if let data = try? WireCodec.encodeLine(AttachReply(ok: false, error: "unknown session \(attach.attach)")) {
                conn.sendRaw(data)
            }
            conn.closeConnection()
            return
        }
        conn.becomeAttached(to: session)
        if let data = try? WireCodec.encodeLine(AttachReply(ok: true)) {
            conn.sendRaw(data)
        }
        session.attach(conn, replay: attach.replay)
    }

    // MARK: - Hook events (daemon queue)

    /// Fire-and-forget line sent by a Claude Code hook; maps hook names to the
    /// session attention state surfaced in the UI.
    func handle(hookEvent: HookEvent) {
        guard let session = sessions[hookEvent.sessionID] else { return }
        let changed: Bool
        switch hookEvent.event {
        case "Notification":
            changed = session.setAttention("permission", message: hookEvent.message)
        case "Stop":
            changed = session.setAttention("done", message: nil)
        default:
            changed = false
        }
        if changed {
            DaemonLog.log("session \(hookEvent.sessionID) attention → \(session.info.attention ?? "nil")")
            broadcast(.sessionsChanged)
        }
    }

    // MARK: - Shutdown

    private func performShutdown() {
        DaemonLog.log("shutting down, terminating \(sessions.values.filter(\.info.isRunning).count) running session(s)")
        for session in sessions.values {
            session.signal(SIGTERM)
        }
        unlink(socketPath)
        exit(0)
    }
}
