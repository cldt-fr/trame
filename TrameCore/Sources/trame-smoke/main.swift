import Darwin
import Foundation
import TrameClient
import TrameProtocol

// End-to-end validation of the V0 acceptance criterion: sessions live in the
// daemon and survive client disconnects (the "quit the app" scenario).

final class OutputCollector {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

var failures = 0

func step(_ name: String, _ ok: Bool, detail: String = "") {
    if ok {
        print("  ✅ \(name)")
    } else {
        failures += 1
        print("  ❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(50_000)
    }
    return condition()
}

func sessions(_ client: DaemonClient) async throws -> [SessionInfo] {
    guard case .sessions(let list) = try await client.call(.listSessions) else { return [] }
    return list
}

func waitForSession(_ client: DaemonClient, id: String, timeout: TimeInterval = 5, _ predicate: @escaping (SessionInfo) -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let s = try? await sessions(client).first(where: { $0.id == id }), predicate(s) { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return false
}

// --- Setup: spawn a dedicated daemon on a temp socket ---

let selfPath = CommandLine.arguments[0]
let buildDir = (selfPath as NSString).deletingLastPathComponent
let daemonPath = buildDir + "/trame-core"
let socketPath = NSTemporaryDirectory() + "trame-smoke-\(getpid()).sock"
let workDir = NSTemporaryDirectory()

print("🔧 démarrage du démon (\(daemonPath))")
print("   socket : \(socketPath)")

let daemonProcess = Process()
daemonProcess.executableURL = URL(fileURLWithPath: daemonPath)
daemonProcess.arguments = ["--socket", socketPath]
daemonProcess.standardOutput = FileHandle.nullDevice
daemonProcess.standardError = FileHandle.nullDevice
try daemonProcess.run()

let client = DaemonClient(socketPath: socketPath)
let connected = waitFor(timeout: 5) { (try? client.connect()) != nil }
step("connexion au démon", connected)
guard connected else { daemonProcess.terminate(); exit(1) }

if case .info(let info) = try await client.call(.daemonInfo) {
    print("  ℹ️  trame-core \(info.version), pid \(info.pid)")
}

// --- 1. Session création + attach + I/O ---

print("1️⃣ création de session + attach + entrée/sortie")
guard case .session(let s1) = try await client.call(.createSession(
    name: nil, cwd: workDir, command: ["/bin/zsh", "-c", "echo READY; cat"],
    env: [:], cols: 80, rows: 24
)) else {
    step("createSession", false, detail: "réponse inattendue")
    exit(1)
}
step("createSession (id \(s1.id), nom auto '\(s1.name)')", true)

let out1 = OutputCollector()
let attach1 = AttachStream()
attach1.onData = { out1.append($0) }
try attach1.attach(socketPath: socketPath, sessionID: s1.id, replay: true)
step("sortie initiale reçue (READY)", waitFor { out1.text.contains("READY") }, detail: out1.text)

attach1.send(Data("hello-trame\n".utf8))
step("écho de l'entrée via le PTY", waitFor { out1.text.contains("hello-trame") }, detail: out1.text)

// --- 2. Détachement / réattachement avec scrollback ---

print("2️⃣ détachement puis réattachement (scrollback)")
attach1.closeStream()
try await Task.sleep(nanoseconds: 200_000_000)

let out2 = OutputCollector()
let attach2 = AttachStream()
attach2.onData = { out2.append($0) }
try attach2.attach(socketPath: socketPath, sessionID: s1.id, replay: true)
step("scrollback rejoué (READY + hello)", waitFor { out2.text.contains("READY") && out2.text.contains("hello-trame") }, detail: out2.text)
attach2.closeStream()

// --- 2b. Événements de hook (attention) ---

print("2️⃣b hooks Claude Code → attention")
func sendHook(_ event: String, message: String? = nil, sessionID: String) throws {
    let fd = try connectUnixSocket(path: socketPath)
    defer { close(fd) }
    let line = try WireCodec.encodeLine(HookEventLine(hookEvent: HookEvent(sessionID: sessionID, event: event, message: message)))
    _ = writeAll(fd, line)
    usleep(100_000)
}

try sendHook("Notification", message: "Claude needs your permission", sessionID: s1.id)
let flagged = await waitForSession(client, id: s1.id) { $0.attention == "permission" }
step("Notification → attention 'permission'", flagged)

let attachClear = AttachStream()
try attachClear.attach(socketPath: socketPath, sessionID: s1.id, replay: false)
attachClear.send(Data("\n".utf8))
let cleared = await waitForSession(client, id: s1.id) { $0.attention == nil }
step("saisie utilisateur → attention effacée", cleared)
attachClear.closeStream()

try sendHook("Stop", sessionID: s1.id)
let done = await waitForSession(client, id: s1.id) { $0.attention == "done" && $0.attentionAt != nil }
step("Stop → attention 'done' (horodatée)", done)

try await client.call(.clearAttention(id: s1.id))
let dismissed = await waitForSession(client, id: s1.id) { $0.attention == nil }
step("clearAttention → attention effacée", dismissed)

// --- 3. Code de sortie ---

print("3️⃣ session qui se termine (code de sortie)")
guard case .session(let s2) = try await client.call(.createSession(
    name: "exit-test", cwd: workDir, command: ["/bin/zsh", "-c", "exit 7"],
    env: [:], cols: 80, rows: 24
)) else {
    step("createSession exit-test", false)
    exit(1)
}
let exited = await waitForSession(client, id: s2.id) { $0.state == .exited(code: 7) }
step("état exited(7) détecté", exited)

// --- 4. LE critère V0 : survie à la déconnexion du client ---

print("4️⃣ survie des sessions à la déconnexion du client (critère V0)")
client.disconnect()
try await Task.sleep(nanoseconds: 300_000_000)

let client2 = DaemonClient(socketPath: socketPath)
try client2.connect()
let survivors = try await sessions(client2)
step("le démon répond après reconnexion", true)
step("la session tourne toujours", survivors.first(where: { $0.id == s1.id })?.isRunning == true)

let out3 = OutputCollector()
let attach3 = AttachStream()
attach3.onData = { out3.append($0) }
try attach3.attach(socketPath: socketPath, sessionID: s1.id, replay: true)
attach3.send(Data("after-reconnect\n".utf8))
step("session toujours interactive", waitFor { out3.text.contains("after-reconnect") }, detail: out3.text)
attach3.closeStream()

// --- 5. Nettoyage ---

print("5️⃣ suppression et arrêt")
try await client2.call(.removeSession(id: s1.id))
try await client2.call(.removeSession(id: s2.id))
let empty = try await sessions(client2)
step("sessions supprimées", empty.isEmpty)
_ = try? await client2.request(.shutdown)
step("démon arrêté", waitFor(timeout: 3) { !daemonProcess.isRunning })
if daemonProcess.isRunning { daemonProcess.terminate() }

print(failures == 0 ? "\n🟢 SMOKE TEST OK — le cœur V0 est validé" : "\n🔴 \(failures) échec(s)")
exit(failures == 0 ? 0 : 1)
