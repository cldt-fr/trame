import AppKit
import Combine
import Foundation
import SwiftUI
import TrameClient
import TrameDaemon
import TrameGit
import TrameMCP
import TrameProtocol
import TrameUsage
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
    @Published var showPalette = false
    @Published var showUsagePanel = false
    /// Estimated cost of the selected session (F7.1), nil while unknown.
    @Published var selectedSessionCost: Double?
    @Published var accounts: [Account] = AccountStore.load()
    private var sessionMetas: [String: SessionMeta] = SessionMetaStore.load()

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
            // An older daemon speaks an older protocol: restart it. The
            // running sessions are recreated from the snapshot right after.
            if case .info(let info) = try await client.call(.daemonInfo), info.version != Daemon.version {
                _ = try? await client.request(.shutdown)
                return // onDisconnect re-enters connect() and respawns
            }
            daemonConnected = true
            lastError = nil
            // Capture the snapshot before refresh() overwrites it with the
            // (possibly empty) state of a freshly-respawned daemon.
            let snapshot = SessionSnapshotStore.load()
            await refresh()
            await restoreSessionsIfNeeded(from: snapshot)
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
            refreshUsage()
            saveSessionSnapshot()
        }
    }

    // MARK: - Session persistence across daemon restarts (F1.7)

    private var isRestoring = false
    private var lastSnapshot: [SessionSnapshot]?

    private func saveSessionSnapshot() {
        guard !isRestoring else { return }
        let snapshots = sessions.map { session in
            SessionSnapshot(
                name: session.name,
                cwd: session.cwd,
                command: session.command,
                accountID: sessionMetas[session.id]?.accountID,
                meshRole: meshMember(for: session.id)?.role,
                wasRunning: session.isRunning
            )
        }
        guard snapshots != lastSnapshot else { return }
        lastSnapshot = snapshots
        SessionSnapshotStore.save(snapshots)
    }

    /// When the daemon comes back with no sessions (reboot, crash, protocol
    /// upgrade), recreates the ones that were running from the snapshot.
    /// Deliberately-emptied states are safe: deleting the last session saves
    /// an empty snapshot, so there is nothing to restore.
    private func restoreSessionsIfNeeded(from snapshot: [SessionSnapshot]) async {
        guard !isRestoring, sessions.isEmpty else { return }
        let snapshots = snapshot.filter(\.wasRunning)
        guard !snapshots.isEmpty else { return }

        isRestoring = true
        for snapshot in snapshots {
            let cmdString = Self.commandString(from: snapshot.command)
            let servers = mcpServers
            var env: [String: String] = [:]
            if let configPath = Self.mcpConfigPath(in: cmdString) {
                env = await Task.detached {
                    MCPStore.resolveEnv(configPath: configPath, servers: servers)
                }.value
            }
            if let accountID = snapshot.accountID, let dir = AccountStore.configDir(for: accountID) {
                env["CLAUDE_CONFIG_DIR"] = dir
            }
            let created = await createSession(cwd: snapshot.cwd, command: cmdString,
                                              name: snapshot.name, env: env,
                                              accountID: snapshot.accountID)
            if let created, let role = snapshot.meshRole {
                meshMembers = meshMembers.map { member in
                    guard member.role == role else { return member }
                    var updated = member
                    updated.id = created.id
                    return updated
                }
                MeshStore.save(meshMembers)
            }
        }
        isRestoring = false
        selectedSessionID = sessions.first?.id
        await refresh()
    }

    // MARK: - Usage & costs (F7)

    /// Claude Code config dirs to scan: the default login plus every account.
    var usageConfigDirs: [String] {
        var dirs = [NSHomeDirectory() + "/.claude"]
        for account in accounts {
            if let dir = AccountStore.configDir(for: account.id) {
                dirs.append(dir)
            }
        }
        return dirs
    }

    private var costRefreshedAt = Date.distantPast
    private var costSessionID: String?
    private var thresholdCheckedAt = Date.distantPast
    private var thresholdAlertedDay: Date?

    private func refreshUsage() {
        updateSelectedSessionCost()
        checkDailyThreshold()
    }

    /// Session cost from its transcript (per config dir + cwd), throttled.
    private func updateSelectedSessionCost() {
        guard let session = selectedSession else {
            selectedSessionCost = nil
            costSessionID = nil
            return
        }
        let selectionChanged = costSessionID != session.id
        guard selectionChanged || Date().timeIntervalSince(costRefreshedAt) > 15 else { return }
        if selectionChanged { selectedSessionCost = nil }
        costRefreshedAt = Date()
        costSessionID = session.id

        let configDir = account(for: session).flatMap { AccountStore.configDir(for: $0.id) }
            ?? NSHomeDirectory() + "/.claude"
        let cwd = session.cwd
        let created = session.createdAt
        let id = session.id
        Task.detached { [weak self] in
            let events = UsageScanner.scan(configDir: configDir, cwd: cwd, since: created)
            let cost = UsageAggregator.totals(events).costUSD
            await MainActor.run {
                guard let self, self.costSessionID == id else { return }
                self.selectedSessionCost = events.isEmpty ? nil : cost
            }
        }
    }

    /// Daily spend alert (F7.3), checked every 5 minutes.
    private func checkDailyThreshold() {
        let limit = UserDefaults.standard.double(forKey: "dailyCostLimit")
        guard limit > 0, Date().timeIntervalSince(thresholdCheckedAt) > 300 else { return }
        thresholdCheckedAt = Date()
        let today = Calendar.current.startOfDay(for: Date())
        guard thresholdAlertedDay != today else { return }
        let dirs = usageConfigDirs
        Task.detached { [weak self] in
            let cost = UsageAggregator.totals(UsageScanner.scan(configDirs: dirs, since: today)).costUSD
            guard cost >= limit else { return }
            await MainActor.run {
                guard let self, self.thresholdAlertedDay != today else { return }
                self.thresholdAlertedDay = today
                let content = UNMutableNotificationContent()
                content.title = "Daily spend limit reached"
                content.body = String(format: "Today's estimated usage is $%.2f (limit $%.2f).", cost, limit)
                content.sound = .default
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: "trame-cost-\(today.timeIntervalSince1970)",
                                          content: content, trigger: nil))
            }
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

    /// One-click fix for the "restart for peers" badge: rewrites PEERS in the
    /// session's existing --mcp-config file, recreates the session with the
    /// same command/account, and transfers the mesh identity to it.
    func restartMeshMemberWithUpdatedPeers(_ member: MeshMember) async {
        guard let session = sessions.first(where: { $0.id == member.id }),
              let cmdString = session.command.last else { return }

        guard let regex = try? NSRegularExpression(pattern: #"--mcp-config "([^"]+)""#),
              let match = regex.firstMatch(in: cmdString, range: NSRange(cmdString.startIndex..., in: cmdString)),
              let pathRange = Range(match.range(at: 1), in: cmdString) else {
            lastError = "Could not locate this session's mcp-config file."
            return
        }
        let configPath = String(cmdString[pathRange])

        let peers = meshMembers
            .filter { $0.id != member.id }
            .map { "\($0.role)=127.0.0.1:\($0.port)" }
            .joined(separator: ",")
        let servers = mcpServers
        let env = await Task.detached {
            MCPStore.updatePeersAndResolveEnv(configPath: configPath, peers: peers, servers: servers)
        }.value
        guard var env else {
            lastError = "Could not update the mesh configuration."
            return
        }

        let accountID = account(for: session)?.id
        if let accountID, let configDir = AccountStore.configDir(for: accountID) {
            env["CLAUDE_CONFIG_DIR"] = configDir
        }
        let peerRoles = meshMembers.filter { $0.id != member.id }.map(\.role)

        // Remove the old session; the guard set keeps the membership alive
        // while no session carries this id.
        restartingMeshIDs.insert(member.id)
        defer { restartingMeshIDs.remove(member.id) }
        _ = try? await client.call(.removeSession(id: member.id))
        let created = await createSession(cwd: session.cwd, command: cmdString,
                                          name: session.name, env: env, accountID: accountID)
        guard let created else {
            leaveMesh(sessionID: member.id)
            return
        }
        var updated = member
        updated.id = created.id
        updated.peerRolesAtLaunch = peerRoles
        meshMembers.removeAll { $0.id == member.id || $0.id == created.id }
        meshMembers.append(updated)
        MeshStore.save(meshMembers)
        await refresh()
    }

    func leaveMesh(sessionID: String) {
        meshMembers.removeAll { $0.id == sessionID }
        MeshStore.save(meshMembers)
    }

    /// Session ids being restarted right now; their mesh membership must
    /// survive the remove→recreate window (the periodic refresh would
    /// otherwise prune them mid-flight and lose the mesh identity).
    private var restartingMeshIDs = Set<String>()

    /// Drops members whose session no longer exists.
    private func pruneMeshMembers() {
        guard !isRestoring else { return }
        let alive = Set(sessions.map(\.id))
        let pruned = meshMembers.filter { alive.contains($0.id) || restartingMeshIDs.contains($0.id) }
        if pruned.count != meshMembers.count {
            meshMembers = pruned
            MeshStore.save(meshMembers)
        }
        let prunedMetas = sessionMetas.filter { alive.contains($0.key) }
        if prunedMetas.count != sessionMetas.count {
            sessionMetas = prunedMetas
            SessionMetaStore.save(sessionMetas)
        }
    }

    /// Review base for a session: the commit it started from, HEAD otherwise.
    func baseCommit(for session: SessionInfo) -> String {
        sessionMetas[session.id]?.baseCommit ?? "HEAD"
    }

    // MARK: - Accounts (F9)

    func account(for session: SessionInfo) -> Account? {
        guard let id = sessionMetas[session.id]?.accountID else { return nil }
        return accounts.first { $0.id == id }
    }

    func saveAccount(_ account: Account) {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx] = account
        } else {
            accounts.append(account)
        }
        AccountStore.save(accounts)
    }

    /// Refuses when live sessions still run under the account (F9.6).
    func deleteAccount(_ account: Account) -> Bool {
        let alive = Set(sessions.map(\.id))
        let inUse = sessionMetas.contains { alive.contains($0.key) && $0.value.accountID == account.id }
        guard !inUse else { return false }
        accounts.removeAll { $0.id == account.id }
        AccountStore.save(accounts)
        return true
    }

    /// One outgoing talkie-walkie message, attributed to its sender (F4.3).
    struct MeshTrafficEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let from: String
        let to: String?
        let text: String
        let isBroadcast: Bool
    }

    /// Mesh traffic recovered from the member sessions' transcripts.
    func loadMeshTraffic() async -> [MeshTrafficEntry] {
        struct Source: Sendable {
            let role: String
            let configDir: String
            let cwd: String
            let since: Date
        }
        let sources: [Source] = meshMembers.compactMap { member in
            guard let session = sessions.first(where: { $0.id == member.id }) else { return nil }
            let configDir = account(for: session).flatMap { AccountStore.configDir(for: $0.id) }
                ?? NSHomeDirectory() + "/.claude"
            return Source(role: member.role, configDir: configDir, cwd: session.cwd, since: session.createdAt)
        }
        let entries = await Task.detached { () -> [(Date, String, String?, String, Bool)] in
            var all: [(Date, String, String?, String, Bool)] = []
            for source in sources {
                for msg in MeshMessageParser.scan(configDir: source.configDir, cwd: source.cwd, since: source.since) {
                    all.append((msg.timestamp, source.role, msg.to, msg.text, msg.isBroadcast))
                }
            }
            return all.sorted { $0.0 > $1.0 }
        }.value
        return entries.prefix(200).map {
            MeshTrafficEntry(timestamp: $0.0, from: $0.1, to: $0.2, text: $0.3, isBroadcast: $0.4)
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
                       mcpServerIDs: [UUID] = [], meshRole: String? = nil,
                       permissionPreset: PermissionPreset = .prudent,
                       accountID: UUID = AccountStore.defaultAccountID) async {
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
            updated.lastPermissionPreset = permissionPreset.rawValue
            updated.lastAccountID = accountID
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

        if permissionPreset != .prudent {
            if isClaudeCommand {
                let allowlist = UserDefaults.standard.string(forKey: "standardAllowlist") ?? PermissionPreset.defaultAllowlist
                let flags = permissionPreset.flags(allowlist: allowlist)
                if !flags.isEmpty {
                    effectiveCommand += " " + flags
                }
            } else {
                lastError = "Permission presets only apply when the command starts with “claude”."
            }
        }

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

        // Isolated login/config per account (F9.1).
        if let configDir = AccountStore.configDir(for: accountID) {
            sessionEnv["CLAUDE_CONFIG_DIR"] = configDir
        }

        let created = await createSession(cwd: cwd, command: effectiveCommand, name: nil, env: sessionEnv,
                                          accountID: accountID == AccountStore.defaultAccountID ? nil : accountID)
        if var member = newMember, let created {
            member.id = created.id
            meshMembers.append(member)
            MeshStore.save(meshMembers)
        }
    }

    /// Runs `command` through a login shell so the user's PATH applies (claude,
    /// nvm, brew…). An empty command opens an interactive shell.
    @discardableResult
    func createSession(cwd: String, command: String, name: String?, env: [String: String] = [:],
                       accountID: UUID? = nil) async -> SessionInfo? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let argv: [String]
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            argv = [shell, "-l"]
        } else {
            argv = [shell, "-l", "-c", trimmed]
        }
        let baseCommit = await Task.detached { () -> String? in
            HookInstaller.install(in: cwd)
            return Git.headCommit(root: cwd)
        }.value
        do {
            let resp = try await client.call(.createSession(
                name: name?.isEmpty == true ? nil : name,
                cwd: cwd, command: argv, env: env, cols: 120, rows: 32
            ))
            if case .session(let info) = resp {
                sessionMetas[info.id] = SessionMeta(baseCommit: baseCommit ?? "HEAD", accountID: accountID)
                SessionMetaStore.save(sessionMetas)
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

    /// Recreates a session with the same command, cwd, name and account —
    /// works for exited sessions ("Start") and running ones ("Restart").
    /// Mesh members are routed through the peers-aware restart.
    func restartSession(_ session: SessionInfo) async {
        if let member = meshMember(for: session.id) {
            await restartMeshMemberWithUpdatedPeers(member)
            return
        }
        let cmdString = Self.commandString(from: session.command)
        let servers = mcpServers
        var env: [String: String] = [:]
        if let configPath = Self.mcpConfigPath(in: cmdString) {
            env = await Task.detached {
                MCPStore.resolveEnv(configPath: configPath, servers: servers)
            }.value
        }
        let accountID = account(for: session)?.id
        if let accountID, let dir = AccountStore.configDir(for: accountID) {
            env["CLAUDE_CONFIG_DIR"] = dir
        }
        _ = try? await client.call(.removeSession(id: session.id))
        await createSession(cwd: session.cwd, command: cmdString,
                            name: session.name, env: env, accountID: accountID)
    }

    /// Recovers the user-level command from the stored argv
    /// ([shell, "-l", "-c", cmd] or [shell, "-l"] for an interactive shell).
    static func commandString(from argv: [String]) -> String {
        if argv.count >= 2, argv[argv.count - 2] == "-c", let last = argv.last {
            return last
        }
        return ""
    }

    static func mcpConfigPath(in command: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"--mcp-config "([^"]+)""#),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let range = Range(match.range(at: 1), in: command) else { return nil }
        return String(command[range])
    }

    func renameSession(_ id: String, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        _ = try? await client.call(.renameSession(id: id, name: trimmed))
        await refresh()
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
