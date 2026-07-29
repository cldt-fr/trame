import Darwin
import Foundation

enum FDIO {
    /// Writes all bytes to a (possibly non-blocking) fd, polling on EAGAIN.
    /// Returns false when the peer is gone.
    static func writeFully(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        let count = data.count
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < count {
                let n = write(fd, base + offset, count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&pfd, 1, 5000) <= 0 { return false }
                default:
                    return false
                }
            }
            return true
        }
    }

    /// Reads whatever is available. Returns nil on EOF or fatal error.
    static func readAvailable(_ fd: Int32, max: Int = 65536) -> Data? {
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            let n = read(fd, &buf, max)
            if n > 0 { return Data(buf[0..<n]) }
            if n == 0 { return nil }
            switch errno {
            case EINTR: continue
            case EAGAIN, EWOULDBLOCK: return Data()
            default: return nil // EIO = pty child exited
            }
        }
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}

enum DaemonLog {
    private static let queue = DispatchQueue(label: "trame.daemon.log")
    private static var handle: FileHandle?

    static func open(path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: path)
        _ = try? handle?.seekToEnd()
    }

    static func log(_ message: String) {
        queue.sync {
            let ts = ISO8601DateFormatter().string(from: Date())
            let line = "[\(ts)] \(message)\n"
            if let data = line.data(using: .utf8) {
                try? handle?.write(contentsOf: data)
            }
            FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
        }
    }
}

/// Runs `body` with argv/envp shaped like execve expects.
func withCStringArray<T>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
    let cStrings = strings.map { strdup($0) }
    defer { cStrings.forEach { free($0) } }
    let array: [UnsafeMutablePointer<CChar>?] = cStrings + [nil]
    return array.withUnsafeBufferPointer { buf in
        body(UnsafePointer(buf.baseAddress!))
    }
}
