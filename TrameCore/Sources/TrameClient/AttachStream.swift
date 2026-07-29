import Darwin
import Foundation
import TrameProtocol

/// Raw attach channel to one session: receives PTY output, sends keyboard input.
public final class AttachStream {
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var closed = false

    /// PTY output bytes, called from a dedicated read thread.
    public var onData: ((Data) -> Void)?
    /// Stream ended (session removed or daemon gone).
    public var onClose: (() -> Void)?

    public init() {}

    public func attach(socketPath: String, sessionID: String, replay: Bool) throws {
        let fd = try connectUnixSocket(path: socketPath)
        let handshake = try WireCodec.encodeLine(AttachRequest(attach: sessionID, replay: replay))
        guard writeAll(fd, handshake) else {
            close(fd)
            throw DaemonClientError.disconnected
        }

        // Read the one-line reply, then everything else is raw output.
        var replyData = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            guard n == 1 else {
                close(fd)
                throw DaemonClientError.disconnected
            }
            if byte == 0x0A { break }
            replyData.append(byte)
            if replyData.count > 4096 {
                close(fd)
                throw DaemonClientError.protocolError("attach reply too long")
            }
        }
        let reply = try WireCodec.decoder.decode(AttachReply.self, from: replyData)
        guard reply.ok else {
            close(fd)
            throw DaemonClientError.daemonError(reply.error ?? "attach refused")
        }

        self.fd = fd
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "trame.attach.read"
        thread.start()
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            lock.lock()
            let currentFD = fd
            lock.unlock()
            guard currentFD >= 0 else { return }
            let n = read(currentFD, &buf, buf.count)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                closeStream()
                return
            }
            onData?(Data(buf[0..<n]))
        }
    }

    public func send(_ data: Data) {
        lock.lock()
        let currentFD = fd
        lock.unlock()
        guard currentFD >= 0 else { return }
        _ = writeAll(currentFD, data)
    }

    public func closeStream() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        if fd >= 0 { close(fd) }
        fd = -1
        lock.unlock()
        onClose?()
    }

    deinit {
        lock.lock()
        if fd >= 0 { close(fd) }
        lock.unlock()
    }
}
