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

    // Initial mission injection (V2/F1.5): typed into the PTY once the
    // program has produced output and gone quiet — i.e. claude is at its
    // prompt — with a hard fallback so it always fires.
    private var pendingInitialInput: String?
    private var initialInputTimer: DispatchSourceTimer?
    private var lastOutputAt: Date?
    private var startedAt = Date()

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
            lastOutputAt = Date()
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
        info.attention = nil
        info.attentionMessage = nil
        info.activity = nil
        info.activitySince = nil
        DaemonLog.log("session \(info.id) exited with code \(code)")
        onExit?(self)
    }

    func rename(_ name: String) {
        info.name = name
    }

    /// Types `input` into the PTY once the program has been quiet for 2s
    /// after producing output (claude sitting at its prompt), or after 25s
    /// no matter what.
    func scheduleInitialInput(_ input: String) {
        pendingInitialInput = input
        startedAt = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.checkInitialInput() }
        initialInputTimer = timer
        timer.resume()
    }

    private func checkInitialInput() {
        guard let input = pendingInitialInput, info.isRunning else {
            initialInputTimer?.cancel()
            initialInputTimer = nil
            pendingInitialInput = nil
            return
        }
        let quietAfterOutput = lastOutputAt.map { Date().timeIntervalSince($0) > 2 } ?? false
        let timedOut = Date().timeIntervalSince(startedAt) > 25
        guard quietAfterOutput || timedOut else { return }
        pendingInitialInput = nil
        initialInputTimer?.cancel()
        initialInputTimer = nil
        writeInput(Data((input + "\r").utf8))
        DaemonLog.log("session \(info.id): initial mission injected")
    }

    /// Returns true when the activity label actually changed. The start time
    /// is anchored to the beginning of the current burst of work.
    func setActivity(_ activity: String?) -> Bool {
        guard info.activity != activity else { return false }
        if activity == nil {
            info.activitySince = nil
        } else if info.activity == nil {
            info.activitySince = Date()
        }
        info.activity = activity
        return true
    }

    /// Returns true when the attention state actually changed.
    func setAttention(_ attention: String?, message: String?) -> Bool {
        guard info.attention != attention || info.attentionMessage != message else { return false }
        info.attention = attention
        info.attentionMessage = message
        info.attentionAt = attention == nil ? nil : Date()
        return true
    }

    func resize(cols: UInt16, rows: UInt16) {
        _ = cpty_resize(masterFD, cols, rows)
    }

    /// Called by the daemon when the user typed into the session; clearing the
    /// attention flag there keeps the two changes on the daemon queue.
    var onUserInput: (() -> Void)?

    func writeInput(_ data: Data) {
        guard info.isRunning else { return }
        _ = FDIO.writeFully(masterFD, data)
        if info.attention != nil {
            onUserInput?()
        }
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
