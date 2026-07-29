import SwiftUI
import TrameProtocol

/// Talkie-walkie mesh: interactive graph of members and remote peers
/// (F4.2/F4.4), health probes, and a live message inspector (F4.3).
struct MeshPanelSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var traffic: [AppModel.MeshTrafficEntry] = []
    /// Reachability per node: "m-<sessionID>" and "r-<peerID>".
    @State private var health: [String: Bool] = [:]
    @State private var showAddRemote = false
    @State private var secretCopied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Talkie-Walkie Mesh")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    showAddRemote = true
                } label: {
                    Label("Add Remote Peer", systemImage: "globe.badge.chevron.backward")
                        .font(.caption)
                }
                .popover(isPresented: $showAddRemote, arrowEdge: .bottom) {
                    AddRemotePeerForm()
                        .environmentObject(model)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)

            if model.meshMembers.isEmpty && model.remotePeers.isEmpty {
                ContentUnavailableView(
                    "No mesh members",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Enable “Join talkie-walkie mesh” when creating a session. Agents then talk to each other by role — e.g. ask the “reviewer” to check the code.")
                )
                .frame(maxHeight: .infinity)
            } else {
                MeshGraphView(traffic: traffic, health: health)
                    .frame(height: 230)
                    .padding(.horizontal, 16)

                Divider()

                inspector
            }

            Divider()
            HStack(spacing: 10) {
                Button {
                    if let secret = MeshStore.secret() {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(secret, forType: .string)
                        secretCopied = true
                    }
                } label: {
                    Label(secretCopied ? "Secret Copied" : "Copy Mesh Secret", systemImage: "key")
                        .font(.caption)
                }
                .help("INTERCOM_SECRET to configure talkie-walkie on a remote machine")
                Text("Remote peers need the same secret and a reachable network path (VPN/Tailscale recommended).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 600, height: 580)
        .task {
            while !Task.isCancelled {
                traffic = await model.loadMeshTraffic()
                await probeHealth()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func probeHealth() async {
        struct Probe: Sendable {
            let key: String
            let host: String
            let port: Int
        }
        var probes: [Probe] = model.meshMembers.compactMap { member in
            guard model.sessions.first(where: { $0.id == member.id })?.isRunning == true else { return nil }
            return Probe(key: "m-\(member.id)", host: "127.0.0.1", port: member.port)
        }
        probes += model.remotePeers.map { Probe(key: "r-\($0.id)", host: $0.host, port: $0.port) }
        let results = await Task.detached { () -> [String: Bool] in
            var r: [String: Bool] = [:]
            for probe in probes {
                r[probe.key] = HealthCheck.tcpProbe(host: probe.host, port: probe.port)
            }
            return r
        }.value
        health = results
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

private struct AddRemotePeerForm: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var role = ""
    @State private var host = ""
    @State private var port = "8788"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remote Peer")
                .font(.headline)
            TextField("Role", text: $role, prompt: Text("office-mac"))
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
            HStack(spacing: 6) {
                TextField("Host", text: $host, prompt: Text("100.64.0.12"))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                TextField("Port", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .frame(width: 60)
            }
            Text("The remote machine must run talkie-walkie with the same INTERCOM_SECRET (Copy Mesh Secret below). New sessions include it in PEERS; existing members show the restart badge.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 240)
            HStack {
                Spacer()
                Button("Add") {
                    if let p = Int(port), !role.isEmpty, !host.isEmpty {
                        model.addRemotePeer(role: role, host: host, port: p)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(role.isEmpty || host.isEmpty || Int(port) == nil)
            }
        }
        .padding(14)
    }
}

/// Circular graph: local members and remote peers, full mesh.
private struct MeshGraphView: View {
    @EnvironmentObject private var model: AppModel
    let traffic: [AppModel.MeshTrafficEntry]
    let health: [String: Bool]

    private enum Node: Identifiable {
        case member(MeshMember)
        case remote(RemotePeer)

        var id: String {
            switch self {
            case .member(let m): return "m-\(m.id)"
            case .remote(let p): return "r-\(p.id)"
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let nodes: [Node] = model.meshMembers.map(Node.member) + model.remotePeers.map(Node.remote)
            let positions = nodePositions(count: nodes.count, in: geo.size)

            ZStack {
                Path { path in
                    for i in nodes.indices {
                        for j in nodes.indices where j > i {
                            path.move(to: positions[i])
                            path.addLine(to: positions[j])
                        }
                    }
                }
                .stroke(Color.accentColor.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))

                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    Group {
                        switch node {
                        case .member(let member): memberNode(member)
                        case .remote(let peer): remoteNode(peer)
                        }
                    }
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
    private func memberNode(_ member: MeshMember) -> some View {
        let session = model.sessions.first { $0.id == member.id }
        let isRunning = session?.isRunning == true
        let stale = model.isMeshStale(member)
        let dead = isRunning && health["m-\(member.id)"] == false
        let recentlyActive = traffic.first { $0.from == member.role }
            .map { Date().timeIntervalSince($0.timestamp) < 120 } ?? false

        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(isRunning ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                    .frame(width: 46, height: 46)
                Circle()
                    .strokeBorder(dead ? Color.red : (stale ? Color.orange : (isRunning ? Color.accentColor : Color.secondary.opacity(0.4))),
                                  lineWidth: (dead || stale) ? 2 : 1.5)
                    .frame(width: 46, height: 46)
                Image(systemName: recentlyActive ? "antenna.radiowaves.left.and.right" : "person.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(isRunning ? Color.accentColor : Color.secondary)
            }
            Text(member.role)
                .font(.caption.monospaced().weight(.medium))
                .lineLimit(1)
            if dead {
                Text("intercom down")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.red)
            } else if stale {
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
        .help(dead
              ? "The talkie-walkie server is not listening on port \(member.port)."
              : (stale
                 ? "Launched before the current peer list — restart this session to see new peers."
                 : "127.0.0.1:\(member.port)"))
    }

    @ViewBuilder
    private func remoteNode(_ peer: RemotePeer) -> some View {
        let reachable = health["r-\(peer.id)"]

        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.teal.opacity(0.12))
                    .frame(width: 46, height: 46)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(reachable == false ? Color.red : Color.teal,
                                  style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    .frame(width: 46, height: 46)
                Image(systemName: "globe")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.teal)
            }
            Text(peer.role)
                .font(.caption.monospaced().weight(.medium))
                .lineLimit(1)
            Text(reachable == false ? "unreachable" : "remote")
                .font(.system(size: 8))
                .foregroundStyle(reachable == false ? Color.red : Color.secondary)
        }
        .contextMenu {
            Button("Remove Remote Peer") { model.removeRemotePeer(peer) }
        }
        .help("\(peer.host):\(peer.port)")
    }
}
