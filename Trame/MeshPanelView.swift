import SwiftUI
import TrameProtocol

/// Talkie-walkie mesh: interactive graph of members (F4.2) and a live
/// inspector of the messages they exchange (F4.3).
struct MeshPanelSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var traffic: [AppModel.MeshTrafficEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Talkie-Walkie Mesh")
                    .font(.title2.weight(.semibold))
                Spacer()
                if !model.meshMembers.isEmpty {
                    Text("\(model.meshMembers.count) member(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)

            if model.meshMembers.isEmpty {
                ContentUnavailableView(
                    "No mesh members",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Enable “Join talkie-walkie mesh” when creating a session. Agents then talk to each other by role — e.g. ask the “reviewer” to check the code.")
                )
                .frame(maxHeight: .infinity)
            } else {
                MeshGraphView(traffic: traffic)
                    .frame(height: 230)
                    .padding(.horizontal, 16)

                Divider()

                inspector
            }

            Divider()
            HStack {
                Text("Messages are read from the senders' session transcripts.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 580, height: 560)
        .task {
            while !Task.isCancelled {
                traffic = await model.loadMeshTraffic()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private var inspector: some View {
        List {
            if traffic.isEmpty {
                Text("No messages yet. Ask an agent to use talkie-walkie — e.g. “ask the reviewer to check my diff”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(traffic) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: entry.isBroadcast ? "megaphone.fill" : "arrow.right.circle.fill")
                        .font(.caption)
                        .foregroundStyle(entry.isBroadcast ? Color.orange : Color.accentColor)
                        .frame(width: 16)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(entry.from)
                                .font(.caption.monospaced().weight(.semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                            Text(entry.isBroadcast ? "all" : (entry.to ?? "?"))
                                .font(.caption.monospaced().weight(.semibold))
                            Spacer()
                            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset)
    }
}

/// Circular graph: every member can talk to every other (full mesh).
private struct MeshGraphView: View {
    @EnvironmentObject private var model: AppModel
    let traffic: [AppModel.MeshTrafficEntry]

    var body: some View {
        GeometryReader { geo in
            let members = model.meshMembers
            let positions = nodePositions(count: members.count, in: geo.size)

            ZStack {
                // Full-mesh edges.
                Path { path in
                    for i in members.indices {
                        for j in members.indices where j > i {
                            path.move(to: positions[i])
                            path.addLine(to: positions[j])
                        }
                    }
                }
                .stroke(Color.accentColor.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))

                ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                    nodeView(member)
                        .position(positions[index])
                }
            }
        }
    }

    private func nodePositions(count: Int, in size: CGSize) -> [CGPoint] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        guard count > 1 else { return [center] }
        let radius = min(size.width, size.height) / 2 - 46
        return (0..<count).map { i in
            let angle = 2 * .pi * Double(i) / Double(count) - .pi / 2
            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
    }

    @ViewBuilder
    private func nodeView(_ member: MeshMember) -> some View {
        let session = model.sessions.first { $0.id == member.id }
        let isRunning = session?.isRunning == true
        let stale = model.isMeshStale(member)
        let recentlyActive = traffic.first { $0.from == member.role }
            .map { Date().timeIntervalSince($0.timestamp) < 120 } ?? false

        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(isRunning ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                    .frame(width: 46, height: 46)
                Circle()
                    .strokeBorder(stale ? Color.orange : (isRunning ? Color.accentColor : Color.secondary.opacity(0.4)),
                                  lineWidth: stale ? 2 : 1.5)
                    .frame(width: 46, height: 46)
                Image(systemName: recentlyActive ? "antenna.radiowaves.left.and.right" : "person.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(isRunning ? Color.accentColor : Color.secondary)
            }
            Text(member.role)
                .font(.caption.monospaced().weight(.medium))
                .lineLimit(1)
            if stale {
                Text("restart for peers")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.orange)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if session != nil { model.focusSession(member.id) }
        }
        .contextMenu {
            if session != nil {
                Button("Open Session") { model.focusSession(member.id) }
            }
            if stale {
                Button("Restart with Updated Peers") {
                    Task { await model.restartMeshMemberWithUpdatedPeers(member) }
                }
            }
            Button("Leave Mesh") { model.leaveMesh(sessionID: member.id) }
        }
        .help(stale
              ? "Launched before the current member list — restart this session to see new peers."
              : "127.0.0.1:\(member.port)")
    }
}
