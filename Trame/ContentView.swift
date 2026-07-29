import SwiftUI
import TrameProtocol

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 265)
        } detail: {
            detail
        }
        .overlay(alignment: .top) {
            if model.showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001)
                        .onTapGesture { model.showPalette = false }
                    CommandPalette()
                        .environmentObject(model)
                        .padding(.top, 60)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $model.showCreateSheet) {
            CreateSessionSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showMCPLibrary) {
            MCPLibrarySheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showMeshPanel) {
            MeshPanelSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showUsagePanel) {
            UsagePanelSheet()
                .environmentObject(model)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.showUsagePanel = true
                } label: {
                    Label("Usage", systemImage: "chart.bar")
                }
                .help("Usage & costs")
            }
            ToolbarItem {
                Button {
                    model.showMeshPanel = true
                } label: {
                    Label("Mesh", systemImage: "antenna.radiowaves.left.and.right")
                }
                .help("Talkie-walkie mesh")
            }
            ToolbarItem {
                Button {
                    model.showMCPLibrary = true
                } label: {
                    Label("MCP Library", systemImage: "server.rack")
                }
                .help("MCP server library")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openCreateSheet(project: model.selectedSession.flatMap { model.project(for: $0) })
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .help("New session (⌘N)")
                .disabled(model.projects.isEmpty)
            }
        }
    }

    private func openCreateSheet(project: Project?) {
        model.createSheetProject = project ?? model.projects.first
        model.showCreateSheet = true
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedSessionID) {
                if !model.attentionSessions.isEmpty {
                    Section("Inbox") {
                        ForEach(model.attentionSessions) { session in
                            InboxRow(session: session)
                        }
                    }
                }
                ForEach(model.projects) { project in
                    Section {
                        ForEach(model.sessions(of: project)) { session in
                            sessionRow(session)
                        }
                    } header: {
                        ProjectHeader(project: project) {
                            openCreateSheet(project: project)
                        }
                        .contextMenu {
                            Button("New Session…") { openCreateSheet(project: project) }
                            Button("Remove Project") { model.unregisterProject(project) }
                        }
                    }
                }
                if !model.unassignedSessions.isEmpty {
                    Section("Other") {
                        ForEach(model.unassignedSessions) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if model.projects.isEmpty && model.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No Projects", systemImage: "square.stack.3d.up")
                    } description: {
                        Text("Add a git repository to get started.")
                    } actions: {
                        Button("Add Project") { pickProject() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }

            statusBar
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Button {
                pickProject()
            } label: {
                Label("Add Project", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(model.daemonConnected ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(model.daemonConnected ? "\(model.sessions.filter(\.isRunning).count) running" : "offline")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .help(model.daemonConnected ? "Daemon connected" : "Daemon offline")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func sessionRow(_ session: SessionInfo) -> some View {
        SessionRow(session: session,
                   isWorktree: model.isWorktreeSession(session),
                   meshRole: model.meshMember(for: session.id)?.role,
                   account: model.account(for: session))
            .tag(session.id)
            .contextMenu {
                if session.isRunning {
                    Button("Stop") {
                        Task { await model.stopSession(session.id) }
                    }
                }
                if model.isWorktreeSession(session) {
                    Button("Delete (Session + Worktree)", role: .destructive) {
                        Task { await model.removeSessionAndWorktree(session) }
                    }
                } else {
                    Button("Delete", role: .destructive) {
                        Task { await model.removeSession(session.id) }
                    }
                }
            }
    }

    private func pickProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a git repository"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.addProject(from: url) }
        }
    }

    // MARK: - Detail

    @State private var detailTab: DetailTab = .terminal

    enum DetailTab {
        case terminal, changes
    }

    @ViewBuilder
    private var detail: some View {
        if let session = model.selectedSession {
            VStack(spacing: 0) {
                SessionHeader(session: session, tab: $detailTab)
                // The terminal stays mounted (hidden) so the attach stream and
                // scrollback survive switching to the Changes tab.
                ZStack {
                    TerminalHostView(sessionID: session.id)
                        .id(session.id)
                        .opacity(detailTab == .terminal ? 1 : 0)
                        .allowsHitTesting(detailTab == .terminal)
                    if detailTab == .changes {
                        ChangesView(session: session)
                            .id(session.id)
                            .background(Color(nsColor: .textBackgroundColor))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.separator.opacity(0.5))
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
        } else {
            ContentUnavailableView {
                Label("No Session", systemImage: "terminal")
            } description: {
                Text(model.lastError ?? "Create a session with ⌘N, or press ⌘K.")
            } actions: {
                if !model.projects.isEmpty {
                    Button("New Session") {
                        openCreateSheet(project: model.projects.first)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }
}

// MARK: - Rows

struct InboxRow: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionInfo

    private var isDone: Bool { session.attention == "done" }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "bell.badge.fill")
                .font(.caption)
                .foregroundStyle(isDone ? Color.blue : Color.orange)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .lineLimit(1)
                Text(isDone ? "Finished its turn" : (session.attentionMessage ?? "Needs your attention"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Button {
                Task { await model.dismissAttention(session.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedSessionID = session.id
        }
        .padding(.vertical, 1)
    }
}

struct ProjectHeader: View {
    let project: Project
    let onNewSession: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(project.name)
            Spacer()
            Button(action: onNewSession) {
                Image(systemName: "plus")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .help("New session in \(project.name)")
        }
        .onHover { hovering = $0 }
    }
}

struct SessionRow: View {
    let session: SessionInfo
    let isWorktree: Bool
    var meshRole: String?
    var account: Account?

    private var subtitle: [(String, String)] {
        var parts: [(String, String)] = []
        if isWorktree {
            parts.append(("arrow.triangle.branch", (session.cwd as NSString).lastPathComponent))
        }
        if let meshRole {
            parts.append(("antenna.radiowaves.left.and.right", meshRole))
        }
        return parts
    }

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(session.isRunning ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.name)
                        .lineLimit(1)
                    if let account {
                        Circle()
                            .fill(AccountStore.color(for: account))
                            .frame(width: 6, height: 6)
                            .help("Account: \(account.name)")
                    }
                    if PermissionPreset.isAutonomous(session) {
                        Image(systemName: "shield.slash.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.orange)
                            .help("Autonomous: permission prompts are skipped")
                    }
                }
                if !subtitle.isEmpty {
                    HStack(spacing: 7) {
                        ForEach(subtitle, id: \.1) { icon, text in
                            HStack(spacing: 3) {
                                Image(systemName: icon)
                                    .font(.system(size: 8))
                                Text(text)
                                    .font(.caption2)
                            }
                        }
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailingBadge
        }
        .padding(.vertical, 1)
        .help((session.cwd as NSString).abbreviatingWithTildeInPath)
    }

    @ViewBuilder
    private var trailingBadge: some View {
        if session.isRunning, let attention = session.attention {
            Image(systemName: attention == "done" ? "checkmark.circle.fill" : "bell.badge.fill")
                .font(.caption)
                .foregroundStyle(attention == "done" ? Color.blue : Color.orange)
        } else if case .exited(let code) = session.state {
            Text("exit \(code)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(code == 0 ? Color.secondary.opacity(0.7) : Color.orange)
        }
    }
}

// MARK: - Session header

struct SessionHeader: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionInfo
    @Binding var tab: ContentView.DetailTab

    private var subtitle: String {
        var parts: [String] = []
        if let project = model.project(for: session) {
            parts.append(project.name)
        }
        if model.isWorktreeSession(session) {
            parts.append((session.cwd as NSString).lastPathComponent)
        }
        if let role = model.meshMember(for: session.id)?.role {
            parts.append("mesh: \(role)")
        }
        if let account = model.account(for: session) {
            parts.append(account.name)
        }
        if case .exited(let code) = session.state {
            parts.append("exited (\(code))")
        }
        if let cost = model.selectedSessionCost {
            parts.append(String(format: "~$%.2f", cost))
        }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(session.isRunning ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(session.name)
                        .font(.title3.weight(.semibold))
                    if PermissionPreset.isAutonomous(session) {
                        Label("Autonomous", systemImage: "shield.slash.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                            .help("Permission prompts are skipped in this session")
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if session.isRunning, let attention = session.attention, attention != "done" {
                Label(session.attentionMessage ?? "Needs your attention", systemImage: "bell.badge.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                    .frame(maxWidth: 320, alignment: .trailing)
            }

            Picker("", selection: $tab) {
                Text("Terminal").tag(ContentView.DetailTab.terminal)
                Text("Changes").tag(ContentView.DetailTab.changes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Menu {
                if session.isRunning {
                    Button("Stop") {
                        Task { await model.stopSession(session.id) }
                    }
                }
                if model.isWorktreeSession(session) {
                    Button("Delete (Session + Worktree)", role: .destructive) {
                        Task { await model.removeSessionAndWorktree(session) }
                    }
                } else {
                    Button("Delete", role: .destructive) {
                        Task { await model.removeSession(session.id) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}
