import Darwin
import Foundation
import TrameProtocol

public enum DaemonClientError: Error, LocalizedError {
    case connectFailed(String)
    case disconnected
    case protocolError(String)
    case daemonError(String)

    public var errorDescription: String? {
        switch self {
        case .connectFailed(let path): return "Could not connect to the daemon (\(path))"
        case .disconnected: return "Lost connection to the daemon"
        case .protocolError(let msg): return "Protocol error: \(msg)"
        case .daemonError(let msg): return msg
        }
    }
}

func connectUnixSocket(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw DaemonClientError.connectFailed(path) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
    let copied = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        path.withCString { cPath in
            strlcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cPath, pathCapacity)
        }
    }
    guard copied < pathCapacity else {
        close(fd)
        throw DaemonClientError.connectFailed("path too long: \(path)")
    }
    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        close(fd)
        throw DaemonClientError.connectFailed(path)
    }
    return fd
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var offset = 0
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard let base = raw.baseAddress else { return true }
        while offset < data.count {
            let n = write(fd, base + offset, data.count - offset)
            if n > 0 { offset += n; continue }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&pfd, 1, 5000) <= 0 { return false }
                continue
            }
            return false
        }
        return true
    }
}

/// Control-channel client. Thread-safe; responses are correlated by request id.
public final class DaemonClient {
    public let socketPath: String
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: (Result<DaemonResponse, Error>) -> Void] = [:]
    private var readThread: Thread?

    /// Called (on an arbitrary thread) for daemon-pushed events.
    public var onEvent: ((DaemonEvent) -> Void)?
    /// Called when the control connection drops.
    public var onDisconnect: (() -> Void)?

    public init(socketPath: String = TramePaths.socketPath) {
        self.socketPath = socketPath
    }

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0
    }

    public func connect() throws {
        lock.lock()
        defer { lock.unlock() }
        guard fd < 0 else { return }
        fd = try connectUnixSocket(path: socketPath)
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "trame.client.read"
        readThread = thread
        thread.start()
    }

    /// Connects, spawning the daemon executable when nothing answers.
    public func ensureConnected(daemonLauncher: () throws -> Void, timeout: TimeInterval = 5) throws {
        if isConnected { return }
        if (try? connect()) != nil { return }
        try daemonLauncher()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(150_000)
            if (try? connect()) != nil { return }
        }
        throw DaemonClientError.connectFailed(socketPath)
    }

    private func readLoop() {
        let lineBuffer = LineBuffer()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            lock.lock()
            let currentFD = fd
            lock.unlock()
            guard currentFD >= 0 else { return }

            let n = read(currentFD, &buf, buf.count)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                handleDisconnect()
                return
            }
            for line in lineBuffer.append(Data(buf[0..<n])) {
                guard let server = try? WireCodec.decoder.decode(ServerLine.self, from: line) else { continue }
                if server.id == 0 {
                    if let event = server.event { onEvent?(event) }
                } else {
                    lock.lock()
                    let handler = pending.removeValue(forKey: server.id)
                    lock.unlock()
                    handler?(.success(server.resp ?? .ok))
                }
            }
        }
    }

    private func handleDisconnect() {
        lock.lock()
        if fd >= 0 { close(fd) }
        fd = -1
        let handlers = pending
        pending = [:]
        lock.unlock()
        for handler in handlers.values {
            handler(.failure(DaemonClientError.disconnected))
        }
        onDisconnect?()
    }

    public func request(_ req: DaemonRequest, completion: @escaping (Result<DaemonResponse, Error>) -> Void) {
        lock.lock()
        guard fd >= 0 else {
            lock.unlock()
            completion(.failure(DaemonClientError.disconnected))
            return
        }
        let id = nextID
        nextID += 1
        pending[id] = completion
        let currentFD = fd
        lock.unlock()

        guard let data = try? WireCodec.encodeLine(RequestLine(id: id, req: req)) else {
            completion(.failure(DaemonClientError.protocolError("encode")))
            return
        }
        if !writeAll(currentFD, data) {
            handleDisconnect()
        }
    }

    public func request(_ req: DaemonRequest) async throws -> DaemonResponse {
        try await withCheckedThrowingContinuation { continuation in
            request(req) { continuation.resume(with: $0) }
        }
    }

    /// Convenience: throws on `.error` responses.
    @discardableResult
    public func call(_ req: DaemonRequest) async throws -> DaemonResponse {
        let resp = try await request(req)
        if case .error(let message) = resp {
            throw DaemonClientError.daemonError(message)
        }
        return resp
    }

    public func disconnect() {
        handleDisconnect()
    }
}
