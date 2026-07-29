import SwiftUI
import TrameMCP

struct MCPLibrarySheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var editingServer: MCPServer?
    @State private var editingProfile: MCPProfile?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("MCP Library")
                    .font(.title3.bold())
                Spacer()
                Picker("", selection: $tab) {
                    Text("Servers").tag(0)
                    Text("Profiles").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            if tab == 0 {
                serversTab
            } else {
                profilesTab
            }

            HStack {
                if tab == 0 {
                    Button("Add Server") {
                        editingServer = MCPServer(name: "", transport: .stdio)
                    }
                } else {
                    Button("Add Profile") {
                        editingProfile = MCPProfile(name: "")
                    }
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 440)
        .sheet(item: $editingServer) { server in
            MCPServerEditor(server: server)
                .environmentObject(model)
        }
        .sheet(item: $editingProfile) { profile in
            MCPProfileEditor(profile: profile)
                .environmentObject(model)
        }
    }

    private var serversTab: some View {
        List {
            if model.mcpServers.isEmpty {
                Text("No MCP servers yet. Define a server once, attach it to any session.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.mcpServers) { server in
                HStack {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.name).font(.body)
                        Text(server.transport == .stdio ? server.commandLine : server.url)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(server.transport.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    Button("Edit") { editingServer = server }
                        .controlSize(.small)
                }
            }
        }
    }

    private var profilesTab: some View {
        List {
            if model.mcpProfiles.isEmpty {
                Text("Profiles bundle several servers (e.g. “Web Stack”) so you can attach them in one click.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.mcpProfiles) { profile in
                HStack {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.name).font(.body)
                        Text(profile.serverIDs.compactMap { id in
                            model.mcpServers.first { $0.id == id }?.name
                        }.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") { editingProfile = profile }
                        .controlSize(.small)
                }
            }
        }
    }
}

struct MCPServerEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var server: MCPServer

    private var isNew: Bool {
        !model.mcpServers.contains { $0.id == server.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New MCP Server" : "Edit MCP Server")
                .font(.title3.bold())

            LabeledContent("Name") {
                TextField("postgres", text: $server.name)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Transport") {
                Picker("", selection: $server.transport) {
                    ForEach(MCPTransport.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if server.transport == .stdio {
                LabeledContent("Command") {
                    TextField("npx -y @modelcontextprotocol/server-postgres", text: $server.commandLine)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
            } else {
                LabeledContent("URL") {
                    TextField("https://…", text: $server.url)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Environment variables")
                    .font(.headline)
                ForEach($server.env) { $envVar in
                    HStack(spacing: 6) {
                        TextField("KEY", text: $envVar.key)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                            .frame(width: 150)
                        if envVar.isSecret {
                            SecureField("value (Keychain)", text: $envVar.value)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            TextField("value", text: $envVar.value)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced())
                        }
                        Toggle("Secret", isOn: $envVar.isSecret)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                        Button {
                            server.env.removeAll { $0.id == envVar.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Add Variable") {
                    server.env.append(MCPEnvVar(key: "", value: "", isSecret: false))
                }
                .controlSize(.small)
                Text("Secret values are stored in the macOS Keychain and injected at launch — never written to disk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        model.deleteMCPServer(server)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveMCPServer(server)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(server.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            // Show stored secrets so they can be reviewed/edited.
            server.env = server.env.map { envVar in
                var v = envVar
                if v.isSecret, v.value.isEmpty {
                    v.value = KeychainStore.get(account: MCPStore.secretAccount(serverID: server.id, key: v.key)) ?? ""
                }
                return v
            }
        }
    }
}

struct MCPProfileEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var profile: MCPProfile

    private var isNew: Bool {
        !model.mcpProfiles.contains { $0.id == profile.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Profile" : "Edit Profile")
                .font(.title3.bold())

            LabeledContent("Name") {
                TextField("Web Stack", text: $profile.name)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Servers")
                .font(.headline)
            ForEach(model.mcpServers) { server in
                Toggle(server.name, isOn: Binding(
                    get: { profile.serverIDs.contains(server.id) },
                    set: { on in
                        if on {
                            profile.serverIDs.append(server.id)
                        } else {
                            profile.serverIDs.removeAll { $0 == server.id }
                        }
                    }
                ))
                .toggleStyle(.checkbox)
            }

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        model.deleteMCPProfile(profile)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveMCPProfile(profile)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
