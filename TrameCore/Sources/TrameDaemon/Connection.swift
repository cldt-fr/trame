import Darwin
import Foundation
import TrameProtocol

/// One accepted socket connection. Starts in `handshake` mode: the first JSON
/// line decides whether this is a control channel or a raw attach channel.
final class ClientConnection {
    enum Mode {
        case handshake
        case control
        case attached(Session)
        case closed
    }

    let fd: Int32
    private(set) var mode: Mode = .handshake
    private let daemonQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private let lineBuffer = LineBuffer()
    unowned let daemon: Daemon

    init(fd: Int32, daemon: Daemon, daemonQueue: DispatchQueue) {
        self.fd = fd
        self.daemon = daemon
        self.daemonQueue = daemonQueue
        self.writeQueue = DispatchQueue(label: "trame.daemon.conn.write.\(fd)")
        FDIO.setNonBlocking(fd)
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: daemonQueue)
        source.setEventHandler { [weak self] in self?.pump() }
        source.setCancelHandler { [fd] in close(fd) }
        readSource = source
        source.resume()
    }

    private func pump() {
        while true {
            guard let chunk = FDIO.readAvailable(fd) else {
                closeConnection()
                return
            }
            if chunk.isEmpty { return }
            consume(chunk)
        }
    }

    private func consume(_ chunk: Data) {
        switch mode {
        case .attached(let session):
            session.writeInput(chunk)
        case .handshake, .control:
            for line in lineBuffer.append(chunk) {
                handleLine(line)
                if case .attached(let session) = mode {
                    // Bytes that followed the handshake line are already input.
                    let rest = lineBuffer.drainRemainder()
                    if !rest.isEmpty { session.writeInput(rest) }
                    break
                }
            }
        case .closed:
            break
        }
    }

    private func handleLine(_ line: Data) {
        switch mode {
        case .handshake:
            if let request = try? WireCodec.decoder.decode(RequestLine.self, from: line) {
                mode = .control
                daemon.register(control: self)
                daemon.handle(request: request, from: self)
            } else if let attach = try? WireCodec.decoder.decode(AttachRequest.self, from: line) {
                daemon.handle(attach: attach, from: self)
            } else {
                DaemonLog.log("connection \(fd): unrecognized handshake line, closing")
                closeConnection()
            }
        case .control:
            if let request = try? WireCodec.decoder.decode(RequestLine.self, from: line) {
                daemon.handle(request: request, from: self)
            }
        case .attached, .closed:
            break
        }
    }

    func becomeAttached(to session: Session) {
        mode = .attached(session)
    }

    // MARK: - Sending

    func send(_ line: ServerLine) {
        guard let data = try? WireCodec.encodeLine(line) else { return }
        sendRaw(data)
    }

    func sendRaw(_ data: Data) {
        writeQueue.async { [fd] in
            _ = FDIO.writeFully(fd, data)
        }
    }

    func closeConnection() {
        if case .closed = mode { return }
        if case .attached(let session) = mode {
            session.detach(self)
        }
        daemon.unregister(connection: self)
        mode = .closed
        readSource?.cancel()
        readSource = nil
    }
}
