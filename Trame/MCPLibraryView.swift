import SwiftUI
import TrameMCP

struct MCPLibrarySheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var editingServer: MCPServer?
    @State private var editingProfile: MCPProfile?
    /// Reachability of http/sse servers (F3.5); stdio servers run per
    /// session and are probed on the mesh panel instead.
    @State private var health: [UUID: Bool] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MCP Library")
                    .font(.title2.weight(.semibold))
                Spacer()
                Picker("", selection: $tab) {
                    Text("Servers").tag(0)
                    Text("Profiles").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Group {
                if tab == 0 {
                    serversTab
                } else {
                    profilesTab
                }
            }

            Divider()
            HStack {
                Button {
                    if tab == 0 {
                        editingServer = MCPServer(name: "", transport: .stdio)
                    } else {
                        editingProfile = MCPProfile(name: "")
                    }
                } label: {
                    Label(tab == 0 ? "Add Server" : "Add Profile", systemImage: "plus")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: 440)
        .sheet(item: $editingServer) { server in
            MCPServerEditor(server: server)
                .environmentObject(model)
        }
        .sheet(item: $editingProfile) { profile in
            MCPProfileEditor(profile: profile)
                .environmentObject(model)
        }
        .task {
            let servers = model.mcpServers.filter { $0.transport != .stdio }
            for server in servers {
                health[server.id] = await HealthCheck.httpProbe(url: server.url)
            }
        }
    }

    private var serversTab: some View {
        List {
            ForEach(model.mcpServers) { server in
                Button {
                    editingServer = server
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)
                        if server.transport != .stdio {
                            Circle()
                                .fill(health[server.id] == nil ? Color.secondary.opacity(0.3)
                                      : (health[server.id] == true ? Color.green : Color.red))
                                .frame(width: 7, height: 7)
                                .help(health[server.id] == true ? "Reachable"
                                      : (health[server.id] == false ? "Unreachable" : "Checking…"))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.name)
                            Text(server.transport == .stdio ? server.commandLine : server.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(server.transport.rawValue)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.mcpServers.isEmpty {
                ContentUnavailableView {
                    Label("No MCP Servers", systemImage: "server.rack")
                } description: {
                    Text("Define a server once, attach it to any session.")
                }
            }
        }
    }

    private var profilesTab: some View {
        List {
            ForEach(model.mcpProfiles) { profile in
                Button {
                    editingProfile = profile
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.name)
                            Text(profile.serverIDs.compactMap { id in
                                model.mcpServers.first { $0.id == id }?.name
                            }.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.mcpProfiles.isEmpty {
                ContentUnavailableView {
                    Label("No Profiles", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Bundle servers (e.g. “Web Stack”) to attach them in one click.")
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
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New MCP Server" : server.name)
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)

            Form {
                Section {
                    TextField("Name", text: $server.name, prompt: Text("postgres"))
                    Picker("Transport", selection: $server.transport) {
                        ForEach(MCPTransport.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    if server.transport == .stdio {
                        TextField("Command", text: $server.commandLine,
                                  prompt: Text("npx -y @modelcontextprotocol/server-postgres"))
                            .fontDesign(.monospaced)
                    } else {
                        TextField("URL", text: $server.url, prompt: Text("https://…"))
                            .fontDesign(.monospaced)
                    }
                }

                Section {
                    ForEach($server.env) { $envVar in
                        HStack(spacing: 6) {
                            TextField("KEY", text: $envVar.key)
                                .fontDesign(.monospaced)
                                .frame(width: 140)
                            if envVar.isSecret {
                                SecureField("value", text: $envVar.value)
                            } else {
                                TextField("value", text: $envVar.value)
                                    .fontDesign(.monospaced)
                            }
                            Toggle("Secret", isOn: $envVar.isSecret)
                                .toggleStyle(.checkbox)
                                .controlSize(.small)
                            Button {
                                server.env.removeAll { $0.id == envVar.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        server.env.append(MCPEnvVar(key: "", value: "", isSecret: false))
                    } label: {
                        Label("Add Variable", systemImage: "plus")
                    }
                } header: {
                    Text("Environment")
                } footer: {
                    Text("Secret values are stored in the macOS Keychain and injected at launch — never written to disk.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
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
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(server.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: 460)
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
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New Profile" : profile.name)
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)

            Form {
                Section {
                    TextField("Name", text: $profile.name, prompt: Text("Web Stack"))
                }
                Section("Servers") {
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
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
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
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 420, height: 400)
    }
}
