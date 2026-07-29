import AppKit
import SwiftUI

struct CreateSessionSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var directory: URL?
    @State private var command = "claude"
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nouvelle session")
                .font(.title3.bold())

            LabeledContent("Dossier") {
                HStack {
                    Text(directory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Aucun dossier choisi")
                        .foregroundStyle(directory == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choisir…") { pickDirectory() }
                }
            }

            LabeledContent("Commande") {
                TextField("claude (vide = shell)", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            }

            LabeledContent("Nom") {
                TextField("auto", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            Text("La commande est lancée via votre shell de connexion (PATH complet). Laissez vide pour un shell interactif.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Créer") {
                    guard let directory else { return }
                    let cwd = directory.path
                    let cmd = command
                    let sessionName = name
                    Task {
                        await model.createSession(cwd: cwd, command: cmd, name: sessionName)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(directory == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choisir"
        if panel.runModal() == .OK {
            directory = panel.url
        }
    }
}
