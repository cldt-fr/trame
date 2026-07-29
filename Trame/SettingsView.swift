import SwiftUI

struct TrameSettings: View {
    var body: some View {
        TabView {
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            TemplatesSettings()
                .tabItem { Label("Templates", systemImage: "person.text.rectangle") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 540, height: 440)
    }
}

/// Role templates used by New Session and the team launcher (V2).
struct TemplatesSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: SessionTemplate?

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.templates) { template in
                    Button {
                        editing = template
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.text.rectangle")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(template.name)
                                    if template.meshEnabled {
                                        Label(template.meshRole, systemImage: "antenna.radiowaves.left.and.right")
                                            .font(.caption2)
                                            .foregroundStyle(Color.teal)
                                    }
                                }
                                Text(template.mission.replacingOccurrences(of: "{objective}", with: "…"))
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

            Divider()
            HStack {
                Button {
                    editing = SessionTemplate(name: "New Role")
                } label: {
                    Label("Add Template", systemImage: "plus")
                }
                Spacer()
                Text("Use {objective} in the mission — it is replaced by the team objective at launch.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
        }
        .sheet(item: $editing) { template in
            TemplateEditor(template: template)
                .environmentObject(model)
        }
    }
}

struct TemplateEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var template: SessionTemplate

    private var isNew: Bool {
        !model.templates.contains { $0.id == template.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New Template" : template.name)
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)

            Form {
                Section {
                    TextField("Name", text: $template.name, prompt: Text("Docs writer"))
                    TextField("Command", text: $template.command)
                        .fontDesign(.monospaced)
                    Picker("Permissions", selection: $template.preset) {
                        ForEach(PermissionPreset.allCases) { p in
                            Text(p.label).tag(p.rawValue)
                        }
                    }
                }
                Section {
                    Toggle("Join talkie-walkie mesh", isOn: $template.meshEnabled)
                    if template.meshEnabled {
                        TextField("Mesh role", text: $template.meshRole, prompt: Text("docs"))
                            .fontDesign(.monospaced)
                    }
                }
                Section {
                    TextField("Mission", text: $template.mission, axis: .vertical)
                        .lineLimit(4...8)
                } header: {
                    Text("Mission")
                } footer: {
                    Text("Typed into the session once Claude is ready. {objective} is replaced by the team objective.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        model.deleteTemplate(template)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveTemplate(template)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480, height: 480)
    }
}

/// Anthropic accounts (F9): each one gets an isolated CLAUDE_CONFIG_DIR.
struct AccountsSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var deleteError = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 10, height: 10)
                    Text("Default")
                    Spacer()
                    Text("your regular Claude Code login")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach($model.accounts) { $account in
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(Array(AccountStore.palette.enumerated()), id: \.offset) { index, color in
                                Button {
                                    account.colorIndex = index
                                    model.saveAccount(account)
                                } label: {
                                    Label("Color \(index + 1)", systemImage: "circle.fill")
                                        .tint(color)
                                }
                            }
                        } label: {
                            Circle()
                                .fill(AccountStore.color(for: account))
                                .frame(width: 10, height: 10)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        TextField("Name", text: $account.name)
                            .textFieldStyle(.plain)
                            .onSubmit { model.saveAccount(account) }
                        Spacer()
                        Button {
                            if !model.deleteAccount(account) {
                                deleteError = true
                            }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    let account = Account(
                        id: UUID(),
                        name: "Work",
                        colorIndex: model.accounts.count % AccountStore.palette.count
                    )
                    model.saveAccount(account)
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
            } footer: {
                Text("Each account has its own isolated Claude Code login and settings. The first session you launch on a new account will ask you to sign in (/login) right in the terminal.")
            }
        }
        .formStyle(.grouped)
        .alert("Account in use", isPresented: $deleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Stop or delete the sessions running under this account first.")
        }
    }
}

struct GeneralSettings: View {
    @AppStorage("standardAllowlist") private var standardAllowlist = PermissionPreset.defaultAllowlist
    @AppStorage("pushURL") private var pushURL = ""

    var body: some View {
        Form {
            Section {
                TextField("Allowed tools", text: $standardAllowlist, axis: .vertical)
                    .fontDesign(.monospaced)
                    .font(.caption)
                    .lineLimit(3...6)
            } header: {
                Text("Standard preset allowlist")
            } footer: {
                Text("Comma-separated tools pre-approved by the Standard permission preset (e.g. Read, Bash(git status:*)).")
            }

            Section {
                TextField("Push URL", text: $pushURL, prompt: Text("https://ntfy.sh/your-topic"))
                    .fontDesign(.monospaced)
                    .font(.caption)
            } header: {
                Text("Mobile push relay")
            } footer: {
                Text("Optional. Blocking events (permission requests, finished turns) are POSTed to this URL — works with ntfy.sh or any compatible endpoint. Only the session name and event type are sent, never prompt contents.")
            }
        }
        .formStyle(.grouped)
    }
}
