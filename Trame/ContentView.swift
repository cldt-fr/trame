import SwiftUI
import TrameProtocol

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 280)
        } detail: {
            detail
        }
        .sheet(isPresented: $model.showCreateSheet) {
            CreateSessionSheet()
                .environmentObject(model)
        }
        .toolbar {
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
                    Section("Other Sessions") {
                        ForEach(model.unassignedSessions) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if model.projects.isEmpty && model.sessions.isEmpty {
                    ContentUnavailableView(
                        "No Projects",
                        systemImage: "folder.badge.plus",
                        description: Text("Add a git repository to get started.")
                    )
                }
            }

            Divider()
            HStack(spacing: 6) {
                Button {
                    pickProject()
                } label: {
                    Label("Add Project", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(model.daemonConnected ? .green : .red)
                    .frame(width: 7, height: 7)
                    .help(model.daemonConnected ? "Daemon connected" : "Daemon offline")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func sessionRow(_ session: SessionInfo) -> some View {
        SessionRow(session: session, isWorktree: model.isWorktreeSession(session))
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

    @ViewBuilder
    private var detail: some View {
        if let session = model.selectedSession {
            VStack(spacing: 0) {
                SessionHeader(session: session)
                Divider()
                TerminalHostView(sessionID: session.id)
                    .id(session.id)
            }
        } else {
            ContentUnavailableView(
                "No Session",
                systemImage: "terminal",
                description: Text(model.lastError ?? "Create a session with ⌘N to get started.")
            )
        }
    }
}

struct ProjectHeader: View {
    let project: Project
    let onNewSession: () -> Void

    var body: some View {
        HStack {
            Text(project.name)
            Spacer()
            Button(action: onNewSession) {
                Image(systemName: "plus")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New session in \(project.name)")
        }
    }
}

struct SessionRow: View {
    let session: SessionInfo
    let isWorktree: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .font(.body)
                HStack(spacing: 4) {
                    if isWorktree {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                        Text((session.cwd as NSString).lastPathComponent)
                            .font(.caption2)
                    } else {
                        Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer()
            if case .exited(let code) = session.state {
                Text("exit \(code)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(code == 0 ? .secondary : Color.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

struct SessionHeader: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionInfo

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(session.name)
                .font(.headline)
            if model.isWorktreeSession(session) {
                Label((session.cwd as NSString).lastPathComponent, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if session.isRunning {
                Button("Stop") {
                    Task { await model.stopSession(session.id) }
                }
                .controlSize(.small)
            } else if model.isWorktreeSession(session) {
                Button("Delete (Session + Worktree)") {
                    Task { await model.removeSessionAndWorktree(session) }
                }
                .controlSize(.small)
            } else {
                Button("Delete") {
                    Task { await model.removeSession(session.id) }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
