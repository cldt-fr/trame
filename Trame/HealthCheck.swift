import Darwin
import Foundation

/// Small reachability probes used for mesh peers (F4.4) and MCP server
/// health (F3.5).
nonisolated enum HealthCheck {
    /// Non-blocking TCP connect with a timeout. Any completed connection
    /// counts as reachable.
    static func tcpProbe(host: String, port: Int, timeoutMs: Int32 = 1500) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else {
            return false
        }
        defer { freeaddrinfo(info) }

        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let result = connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen)
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMs) > 0 else { return false }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        return soError == 0
    }

    /// Any HTTP response (even an error status) means the server is up.
    static func httpProbe(url: String, timeout: TimeInterval = 3) async -> Bool {
        guard let u = URL(string: url) else { return false }
        var request = URLRequest(url: u, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    /// Fire-and-forget push relay (spec F5.5) — minimal content only: the
    /// session name and the event type, never prompt contents.
    static func sendPush(urlString: String, title: String, body: String) {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue(title, forHTTPHeaderField: "Title")
        request.httpBody = Data(body.utf8)
        URLSession.shared.dataTask(with: request).resume()
    }
}
