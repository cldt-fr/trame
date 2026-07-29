import CPTY
import Darwin
import Foundation
import TrameProtocol

/// A live (or exited) PTY session owned by the daemon.
final class Session {
    private(set) var info: SessionInfo
    let masterFD: Int32
    let pid: pid_t

    private(set) var scrollback = Data()
    private let scrollbackCap = 512 * 1024

    private var readSource: DispatchSourceRead?
    private var attached: [ObjectIdentifier: ClientConnection] = [:]
    private let queue: DispatchQueue
    var onExit: ((Session) -> Void)?

    init(info: SessionInfo, masterFD: Int32, pid: pid_t, queue: DispatchQueue) {
        self.info = info
        self.masterFD = masterFD
        self.pid = pid
        self.queue = queue
    }

    func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        source.setEventHandler { [weak self] in self?.pumpOutput() }
        source.setCancelHandler { [masterFD] in close(masterFD) }
        readSource = source
        source.resume()
    }

    private func pumpOutput() {
        while true {
            guard let chunk = FDIO.readAvailable(masterFD) else {
                handleExit()
                return
            }
            if chunk.isEmpty { return } // EAGAIN: drained for now
            appendScrollback(chunk)
            for conn in attached.values {
                conn.sendRaw(chunk)
            }
        }
    }

    private func appendScrollback(_ chunk: Data) {
        scrollback.append(chunk)
        if scrollback.count > scrollbackCap {
            scrollback.removeFirst(scrollback.count - scrollbackCap)
        }
    }

    private func handleExit() {
        readSource?.cancel()
        readSource = nil

        var status: Int32 = 0
        var code: Int32 = -1
        if waitpid(pid, &status, 0) == pid {
            if (status & 0x7F) == 0 {
                code = (status >> 8) & 0xFF // WIFEXITED / WEXITSTATUS
            } else {
                code = 128 + (status & 0x7F) // killed by signal
            }
        }
        info.state = .exited(code: code)
        DaemonLog.log("session \(info.id) exited with code \(code)")
        onExit?(self)
    }

    func rename(_ name: String) {
        info.name = name
    }

    func resize(cols: UInt16, rows: UInt16) {
        _ = cpty_resize(masterFD, cols, rows)
    }

    func writeInput(_ data: Data) {
        guard info.isRunning else { return }
        _ = FDIO.writeFully(masterFD, data)
    }

    func signal(_ sig: Int32) {
        guard info.isRunning else { return }
        kill(pid, sig)
    }

    func attach(_ conn: ClientConnection, replay: Bool) {
        attached[ObjectIdentifier(conn)] = conn
        if replay, !scrollback.isEmpty {
            conn.sendRaw(scrollback)
        }
    }

    func detach(_ conn: ClientConnection) {
        attached.removeValue(forKey: ObjectIdentifier(conn))
    }

    /// Force-terminates the child; used when removing a session.
    func destroy() {
        if info.isRunning {
            kill(pid, SIGKILL)
        }
        // handleExit will fire via the read source (EOF/EIO) and reap the child.
    }
}
