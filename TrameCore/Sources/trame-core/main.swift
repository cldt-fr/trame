import Foundation
import TrameDaemon
import TrameProtocol

// Standalone daemon entry point. The socket path can be overridden with
// TRAME_SOCKET (used by tests) or --socket <path>.
var socketPath = TramePaths.socketPath
let args = CommandLine.arguments
if let idx = args.firstIndex(of: "--socket"), idx + 1 < args.count {
    socketPath = args[idx + 1]
}

Daemon(socketPath: socketPath).run()
