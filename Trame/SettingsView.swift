import SwiftUI

struct TrameSettings: View {
    var body: some View {
        TabView {
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 480, height: 340)
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
        }
        .formStyle(.grouped)
    }
}
