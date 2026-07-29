import AppKit
import Combine
import Foundation
import SwiftUI
import TrameClient
import TrameDaemon
import TrameGit
import TrameMCP
import TrameProtocol
import UserNotifications

enum SessionDestination: Hashable {
    /// La branche courante, directement dans le repo.
    case repo
    /// Un worktree géré par Trame sur cette branche (créée si besoin).
    case worktree(branch: String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var selectedSessionID: String?
    @Published var daemonConnected = false
    @Published var lastError: String?
    @Published var showCreateSheet = false
    @Published var projects: [Project] = ProjectStore.load()
    /// Projet présélectionné dans la feuille de création.
    @Published var createSheetProject: Project?
    @Published var mcpServers: [MCPServer]
    @Published var mcpProfiles: [MCPProfile]
    @Published var showMCPLibrary = false
    @Published var meshMembers: [MeshMember] = MeshStore.load()
    @Published var showMeshPanel = false

    init() {
        let library = MCPStore.load()
        mcpServers = library.servers
        mcpProfiles = library.profiles
    }

    let client = DaemonClient()
    private var refreshTimer: Timer?
    /// Last known attention per session, to notify only on transitions.
    private var knownAttention: [String: String] = [:]

    func start() async {
        // Fire and forget: the permission dialog must not block startup.
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
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
            // An older daemon speaks an older protocol: restart it. Running
            // sessions are lost, acceptable while Trame is pre-1.0.
            if case .info(let info) = try await client.call(.daemonInfo), info.version != Daemon.version {
                _ = try? await client.request(.shutdown)
                return // onDisconnect re-enters connect() and respawns
            }
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
            updateAttentionUX()
            pruneMeshMembers()
        }
    }

    /// Dock badge + macOS notifications on attention transitions (F5.2).
    private func updateAttentionUX() {
        var badge = 0
        for session in sessions where session.isRunning {
            guard let attention = session.attention else { continue }
            badge += 1
            let isNewTransition = knownAttention[session.id] != attention
            let userIsLookingAtIt = NSApp.isActive && selectedSessionID == session.id
            if isNewTransition && !userIsLookingAtIt {
                postNotification(for: session, attention: attention)
            }
        }
        knownAttention = Dictionary(uniqueKeysWithValues: sessions.compactMap { s in
            s.attention.map { (s.id, $0) }
        })
        NSApp.dockTile.badgeLabel = badge > 0 ? "\(badge)" : ""
    }

    private func postNotification(for session: SessionInfo, attention: String) {
        let content = UNMutableNotificationContent()
        content.title = session.name
        content.body = attention == "done"
            ? "Claude finished its turn"
            : (session.attentionMessage?.isEmpty == false ? session.attentionMessage! : "Needs your attention")
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "trame-\(session.id)-\(attention)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    var selectedSession: SessionInfo? {
        sessions.first { $0.id == selectedSessionID }
    }

    // MARK: - Inbox

    /// Running sessions waiting on the user: permission requests first, then
    /// finished turns, most recent first (F5.1).
    var attentionSessions: [SessionInfo] {
        sessions
            .filter { $0.isRunning && $0.attention != nil }
            .sorted { a, b in
                if a.attention != b.attention { return a.attention == "permission" }
                return (a.attentionAt ?? .distantPast) > (b.attentionAt ?? .distantPast)
            }
    }

    // MARK: - Mesh (F4)

    func meshMember(for sessionID: String) -> MeshMember? {
        meshMembers.first { $0.id == sessionID }
    }

    /// A member launched before the current topology existed needs a restart
    /// to see the new peers (talkie-walkie reads PEERS at startup, F4.6).
    func isMeshStale(_ member: MeshMember) -> Bool {
        let currentPeers = Set(meshMembers.filter { $0.id != member.id }.map(\.role))
        return currentPeers != Set(member.peerRolesAtLaunch)
    }

    func leaveMesh(sessionID: String) {
        meshMembers.removeAll { $0.id == sessionID }
        MeshStore.save(meshMembers)
    }

    /// Drops members whose session no longer exists.
    private func pruneMeshMembers() {
        let alive = Set(sessions.map(\.id))
        let pruned = meshMembers.filter { alive.contains($0.id) }
        if pruned.count != meshMembers.count {
            meshMembers = pruned
            MeshStore.save(meshMembers)
        }
    }

    func dismissAttention(_ id: String) async {
        _ = try? await client.call(.clearAttention(id: id))
        await refresh()
    }

    /// Brings the app forward and shows the session (used by inbox & menu bar).
    func focusSession(_ id: String) {
        selectedSessionID = id
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Projets

    func addProject(from url: URL) async {
        let path = url.path
        let root = await Task.detached { Git.repositoryRoot(of: path) }.value
        guard let root else {
            lastError = "\(url.lastPathComponent) is not a git repository."
            return
        }
        guard !projects.contains(where: { $0.root == root }) else { return }
        let project = Project(id: UUID(), name: (root as NSString).lastPathComponent, root: root, lastCommand: nil)
        projects.append(project)
        ProjectStore.save(projects)
    }

    /// Retire le projet de Trame ; ne touche ni au repo ni aux sessions.
    func unregisterProject(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        ProjectStore.save(projects)
    }

    func sessions(of project: Project) -> [SessionInfo] {
        let worktreeDir = WorktreeLayout.directory(for: project) + "/"
        return sessions.filter { $0.cwd == project.root || $0.cwd.hasPrefix(worktreeDir) }
    }

    /// Sessions créées hors de tout projet enregistré.
    var unassignedSessions: [SessionInfo] {
        let assigned = Set(projects.flatMap { sessions(of: $0).map(\.id) })
        return sessions.filter { !assigned.contains($0.id) }
    }

    func project(for session: SessionInfo) -> Project? {
        projects.first { session.cwd == $0.root || session.cwd.hasPrefix(WorktreeLayout.directory(for: $0) + "/") }
    }

    func isWorktreeSession(_ session: SessionInfo) -> Bool {
        WorktreeLayout.isManagedWorktree(session.cwd)
    }

    // MARK: - MCP library (F3)

    /// Persists a server; secret values move to the Keychain and never touch
    /// the library JSON.
    func saveMCPServer(_ server: MCPServer) {
        var stored = server
        stored.env = server.env.map { envVar in
            var v = envVar
            if v.isSecret {
                if !v.value.isEmpty {
                    KeychainStore.set(v.value, account: MCPStore.secretAccount(serverID: server.id, key: v.key))
                }
                v.value = ""
            }
            return v
        }
        if let idx = mcpServers.firstIndex(where: { $0.id == server.id }) {
            mcpServers[idx] = stored
        } else {
            mcpServers.append(stored)
        }
        MCPStore.save(servers: mcpServers, profiles: mcpProfiles)
    }

    func deleteMCPServer(_ server: MCPServer) {
        for envVar in server.env where envVar.isSecret {
            KeychainStore.delete(account: MCPStore.secretAccount(serverID: server.id, key: envVar.key))
        }
        mcpServers.removeAll { $0.id == server.id }
        mcpProfiles = mcpProfiles.map { profile in
            var p = profile
            p.serverIDs.removeAll { $0 == server.id }
            return p
        }
        MCPStore.save(servers: mcpServers, profiles: mcpProfiles)
    }

    func saveMCPProfile(_ profile: MCPProfile) {
        if let idx = mcpProfiles.firstIndex(where: { $0.id == profile.id }) {
            mcpProfiles[idx] = profile
        } else {
            mcpProfiles.append(profile)
        }
        MCPStore.save(servers: mcpServers, profiles: mcpProfiles)
    }

    func deleteMCPProfile(_ profile: MCPProfile) {
        mcpProfiles.removeAll { $0.id == profile.id }
        MCPStore.save(servers: mcpServers, profiles: mcpProfiles)
    }

    // MARK: - Actions

    /// Crée une session dans un projet : sur le repo, ou dans un worktree créé
    /// à la volée (F1.2). Mémorise la commande comme défaut du projet (F1.9).
    func createSession(project: Project, destination: SessionDestination, command: String,
                       mcpServerIDs: [UUID] = [], meshRole: String? = nil) async {
        let cwd: String
        switch destination {
        case .repo:
            cwd = project.root
        case .worktree(let branch):
            let trimmedBranch = branch.trimmingCharacters(in: .whitespaces)
            guard !trimmedBranch.isEmpty else {
                lastError = "A branch name is required for a worktree."
                return
            }
            let path = WorktreeLayout.path(for: project, branch: trimmedBranch)
            let root = project.root
            do {
                if !FileManager.default.fileExists(atPath: path) {
                    try await Task.detached {
                        try Git.addWorktree(root: root, path: path, branch: trimmedBranch)
                    }.value
                }
            } catch {
                lastError = "Could not create worktree: \(error.localizedDescription)"
                return
            }
            cwd = path
        }

        if var updated = projects.first(where: { $0.id == project.id }) {
            updated.lastCommand = command.trimmingCharacters(in: .whitespaces)
            updated.lastMCPServerIDs = mcpServerIDs
            projects = projects.map { $0.id == updated.id ? updated : $0 }
            ProjectStore.save(projects)
        }

        // Attach the selected MCP servers via --mcp-config: the file lives in
        // Application Support (never in the repo) and secrets travel only
        // through the session environment (F3.2).
        var effectiveCommand = command.trimmingCharacters(in: .whitespaces)
        var sessionEnv: [String: String] = [:]
        var servers = mcpServers.filter { mcpServerIDs.contains($0.id) }
        let isClaudeCommand = effectiveCommand == "claude" || effectiveCommand.hasPrefix("claude ")

        // Mesh auto-provisioning (F4.1): allocate a port, derive a unique
        // role, wire PEERS to the current members and add the talkie-walkie
        // MCP entry — zero manual configuration.
        var newMember: MeshMember?
        if let meshRole, isClaudeCommand {
            let role = MeshStore.uniqueRole(from: meshRole, members: meshMembers)
            let port = MeshStore.nextFreePort(members: meshMembers)
            servers.append(MeshStore.talkieServer(role: role, port: port, peers: meshMembers))
            newMember = MeshMember(id: "", role: role, port: port,
                                   peerRolesAtLaunch: meshMembers.map(\.role))
        }

        if !servers.isEmpty {
            if isClaudeCommand {
                let launch = await Task.detached { MCPStore.writeLaunchConfig(servers: servers) }.value
                if let launch {
                    effectiveCommand += " --mcp-config \"\(launch.configPath)\""
                    if newMember != nil {
                        effectiveCommand += " \(MeshStore.claudeFlag)"
                    }
                    sessionEnv = launch.env
                }
            } else {
                lastError = "MCP servers and the mesh are only attached when the command starts with “claude”."
            }
        }

        let created = await createSession(cwd: cwd, command: effectiveCommand, name: nil, env: sessionEnv)
        if var member = newMember, let created {
            member.id = created.id
            meshMembers.append(member)
            MeshStore.save(meshMembers)
        }
    }

    /// Runs `command` through a login shell so the user's PATH applies (claude,
    /// nvm, brew…). An empty command opens an interactive shell.
    @discardableResult
    func createSession(cwd: String, command: String, name: String?, env: [String: String] = [:]) async -> SessionInfo? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let argv: [String]
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            argv = [shell, "-l"]
        } else {
            argv = [shell, "-l", "-c", trimmed]
        }
        await Task.detached { HookInstaller.install(in: cwd) }.value
        do {
            let resp = try await client.call(.createSession(
                name: name?.isEmpty == true ? nil : name,
                cwd: cwd, command: argv, env: env, cols: 120, rows: 32
            ))
            if case .session(let info) = resp {
                await refresh()
                selectedSessionID = info.id
                return info
            }
        } catch {
            lastError = error.localizedDescription
        }
        return nil
    }

    /// Supprime la session ET son worktree géré. La branche est conservée
    /// (garde-fou F6.3).
    func removeSessionAndWorktree(_ session: SessionInfo) async {
        guard let project = project(for: session), isWorktreeSession(session) else {
            await removeSession(session.id)
            return
        }
        await removeSession(session.id)
        // Ne pas supprimer le worktree si une autre session l'utilise encore.
        guard !sessions.contains(where: { $0.cwd == session.cwd }) else { return }
        let root = project.root
        let path = session.cwd
        do {
            try await Task.detached {
                try Git.removeWorktree(root: root, path: path, force: true)
            }.value
        } catch {
            lastError = "Worktree was not removed: \(error.localizedDescription)"
        }
    }

    func stopSession(_ id: String) async {
        _ = try? await client.call(.stopSession(id: id))
        await refresh()
    }

    func removeSession(_ id: String) async {
        _ = try? await client.call(.removeSession(id: id))
        leaveMesh(sessionID: id)
        await refresh()
    }

    func resize(_ id: String, cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        client.request(.resize(id: id, cols: UInt16(cols), rows: UInt16(rows))) { _ in }
    }
}
