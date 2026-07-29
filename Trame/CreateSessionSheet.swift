import AppKit
import SwiftUI
import TrameMCP

struct CreateSessionSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var projectID: UUID?
    @State private var useWorktree = false
    @State private var branch = ""
    @State private var command = "claude"
    @State private var selectedMCPIDs: Set<UUID> = []
    @State private var joinMesh = false
    @State private var meshRole = ""
    @State private var preset: PermissionPreset = .prudent
    @State private var showOptions = false
    @AppStorage("standardAllowlist") private var standardAllowlist = PermissionPreset.defaultAllowlist

    private var project: Project? {
        model.projects.first { $0.id == projectID } ?? model.projects.first
    }

    private var optionsSummary: String {
        var parts: [String] = [preset.label]
        if !selectedMCPIDs.isEmpty { parts.append("\(selectedMCPIDs.count) MCP") }
        if joinMesh { parts.append("mesh") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Session")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)

            Form {
                Section {
                    Picker("Project", selection: $projectID) {
                        ForEach(model.projects) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    Picker("Where", selection: $useWorktree) {
                        Text("Current branch").tag(false)
                        Text("New worktree").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if useWorktree {
                        TextField("Branch", text: $branch, prompt: Text("feat/my-feature"))
                            .fontDesign(.monospaced)
                    }
                    TextField("Command", text: $command, prompt: Text("claude (empty = shell)"))
                        .fontDesign(.monospaced)
                } footer: {
                    if useWorktree {
                        Text("An isolated checkout under ~/.trame/worktrees — run several agents on the same repo without conflicts.")
                    }
                }

                Section {
                    DisclosureGroup(isExpanded: $showOptions) {
                        Picker("Permissions", selection: $preset) {
                            ForEach(PermissionPreset.allCases) { p in
                                Text(p.label).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                        permissionFootnote
                        if preset == .standard {
                            TextField("Allowed tools", text: $standardAllowlist)
                                .fontDesign(.monospaced)
                                .font(.caption)
                        }

                        if !model.mcpServers.isEmpty {
                            mcpSection
                        }

                        Toggle("Join talkie-walkie mesh", isOn: $joinMesh)
                        if joinMesh {
                            TextField("Mesh role", text: $meshRole, prompt: Text("backend, reviewer, tester…"))
                                .fontDesign(.monospaced)
                            Text("Other agents address this session by its role. Port, secret and peers are wired automatically.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        LabeledContent("Options", value: optionsSummary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Session") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(project == nil
                              || (useWorktree && branch.trimmingCharacters(in: .whitespaces).isEmpty))
            }
            .padding(16)
        }
        .frame(width: 460, height: 470)
        .onAppear {
            projectID = model.createSheetProject?.id ?? model.projects.first?.id
            if let last = project?.lastCommand, !last.isEmpty {
                command = last
            }
            let known = Set(model.mcpServers.map(\.id))
            selectedMCPIDs = Set(project?.lastMCPServerIDs ?? []).intersection(known)
            meshRole = useWorktree ? branch : (project?.name.lowercased() ?? "")
            if let last = project?.lastPermissionPreset, let p = PermissionPreset(rawValue: last) {
                preset = p
            }
            showOptions = !selectedMCPIDs.isEmpty || preset != .prudent
        }
    }

    @ViewBuilder
    private var permissionFootnote: some View {
        switch preset {
        case .prudent:
            Text("Every tool call asks for approval (Claude Code defaults).")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .standard:
            Text("Pre-approved tools below; everything else asks.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .autonomous:
            Label(
                useWorktree
                    ? "Skips ALL permission prompts. Contained to this worktree, but the agent keeps network access and your credentials."
                    : "Skips ALL permission prompts directly on your main checkout — the agent can modify anything without asking. A worktree is safer.",
                systemImage: "shield.slash"
            )
            .font(.caption)
            .foregroundStyle(useWorktree ? Color.orange : Color.red)
        }
    }

    @ViewBuilder
    private var mcpSection: some View {
        HStack {
            Text("MCP servers")
            Spacer()
            if !model.mcpProfiles.isEmpty {
                Menu("Profile") {
                    ForEach(model.mcpProfiles) { profile in
                        Button(profile.name) {
                            selectedMCPIDs = Set(profile.serverIDs)
                        }
                    }
                    Divider()
                    Button("None") { selectedMCPIDs = [] }
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
        ForEach(model.mcpServers) { server in
            Toggle(server.name, isOn: Binding(
                get: { selectedMCPIDs.contains(server.id) },
                set: { on in
                    if on { selectedMCPIDs.insert(server.id) } else { selectedMCPIDs.remove(server.id) }
                }
            ))
        }
    }

    private func create() {
        guard let project else { return }
        let destination: SessionDestination = useWorktree ? .worktree(branch: branch) : .repo
        let cmd = command
        let mcpIDs = Array(selectedMCPIDs)
        let role: String? = joinMesh
            ? (meshRole.trimmingCharacters(in: .whitespaces).isEmpty ? project.name : meshRole)
            : nil
        let chosenPreset = preset
        Task {
            await model.createSession(project: project, destination: destination, command: cmd,
                                      mcpServerIDs: mcpIDs, meshRole: role,
                                      permissionPreset: chosenPreset)
        }
        dismiss()
    }
}
