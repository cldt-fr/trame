import SwiftUI
import TrameProtocol

/// Membership panel for the talkie-walkie mesh (F4).
struct MeshPanelSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Talkie-Walkie Mesh")
                .font(.title3.bold())

            if model.meshMembers.isEmpty {
                ContentUnavailableView(
                    "No mesh members",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Enable “Join talkie-walkie mesh” when creating a session. Every member can message the others by role (send_message, broadcast_message).")
                )
            } else {
                List(model.meshMembers) { member in
                    let session = model.sessions.first { $0.id == member.id }
                    HStack(spacing: 10) {
                        Circle()
                            .fill(session?.isRunning == true ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(member.role)
                                    .font(.body.monospaced())
                                Text("127.0.0.1:\(member.port)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(session?.name ?? "session gone")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.isMeshStale(member) {
                            Label("Restart to see new peers", systemImage: "exclamationmark.arrow.circlepath")
                                .font(.caption2)
                                .foregroundStyle(Color.orange)
                                .help("PEERS is read at startup: this session was launched with a different member list.")
                        }
                        Button("Leave") {
                            model.leaveMesh(sessionID: member.id)
                        }
                        .controlSize(.small)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if session != nil { model.focusSession(member.id) }
                    }
                }
                Text("Full mesh over localhost — every member can talk to every other. Peer lists are read at launch; new members require restarting older sessions (upstream lib limitation).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 380)
    }
}
