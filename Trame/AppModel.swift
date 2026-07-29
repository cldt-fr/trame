import Combine
import Foundation
import SwiftUI
import TrameClient
import TrameProtocol

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var selectedSessionID: String?
    @Published var daemonConnected = false
    @Published var lastError: String?
    @Published var showCreateSheet = false

    let client = DaemonClient()
    private var refreshTimer: Timer?

    func start() async {
        client.onEvent = { [weak self] event in
            Task { @MainActor in
                if case .sessionsChanged = event {
                    await self?.refresh()
                }
            }
        }
        client.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.daemonConnected = false
                await self?.connect()
            }
        }
        await connect()

        // Safety net on top of daemon events.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func connect() async {
        do {
            try client.ensureConnected(daemonLauncher: {
                let process = Process()
                process.executableURL = Bundle.main.executableURL
                process.arguments = ["--daemon"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
            })
            daemonConnected = true
            lastError = nil
            await refresh()
        } catch {
            daemonConnected = false
            lastError = error.localizedDescription
        }
    }

    func refresh() async {
        guard client.isConnected else { return }
        if case .sessions(let list) = try? await client.call(.listSessions) {
            sessions = list
            if selectedSessionID == nil || !list.contains(where: { $0.id == selectedSessionID }) {
                selectedSessionID = list.first?.id
            }
        }
    }

    var selectedSession: SessionInfo? {
        sessions.first { $0.id == selectedSessionID }
    }

    // MARK: - Actions

    /// Runs `command` through a login shell so the user's PATH applies (claude,
    /// nvm, brew…). An empty command opens an interactive shell.
    func createSession(cwd: String, command: String, name: String?) async {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let argv: [String]
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            argv = [shell, "-l"]
        } else {
            argv = [shell, "-l", "-c", trimmed]
        }
        do {
            let resp = try await client.call(.createSession(
                name: name?.isEmpty == true ? nil : name,
                cwd: cwd, command: argv, env: [:], cols: 120, rows: 32
            ))
            if case .session(let info) = resp {
                await refresh()
                selectedSessionID = info.id
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopSession(_ id: String) async {
        _ = try? await client.call(.stopSession(id: id))
        await refresh()
    }

    func removeSession(_ id: String) async {
        _ = try? await client.call(.removeSession(id: id))
        await refresh()
    }

    func resize(_ id: String, cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        client.request(.resize(id: id, cols: UInt16(cols), rows: UInt16(rows))) { _ in }
    }
}
