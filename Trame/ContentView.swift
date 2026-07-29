import SwiftUI
import TrameProtocol

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
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
                    model.showCreateSheet = true
                } label: {
                    Label("Nouvelle session", systemImage: "plus")
                }
                .help("Nouvelle session (⌘N)")
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedSessionID) {
                Section("Sessions") {
                    ForEach(model.sessions) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                            .contextMenu {
                                if session.isRunning {
                                    Button("Arrêter") {
                                        Task { await model.stopSession(session.id) }
                                    }
                                }
                                Button("Supprimer", role: .destructive) {
                                    Task { await model.removeSession(session.id) }
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(model.daemonConnected ? .green : .red)
                    .frame(width: 7, height: 7)
                Text(model.daemonConnected ? "Démon connecté" : "Démon hors ligne")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

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
                "Aucune session",
                systemImage: "terminal",
                description: Text(model.lastError ?? "Créez une session avec ⌘N pour démarrer.")
            )
        }
    }
}

struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .font(.body)
                Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                    .font(.caption2)
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
            Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if session.isRunning {
                Button("Arrêter") {
                    Task { await model.stopSession(session.id) }
                }
                .controlSize(.small)
            } else {
                Button("Supprimer") {
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
