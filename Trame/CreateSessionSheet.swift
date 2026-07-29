import AppKit
import SwiftUI

struct CreateSessionSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var projectID: UUID?
    @State private var useWorktree = false
    @State private var branch = ""
    @State private var command = "claude"

    private var project: Project? {
        model.projects.first { $0.id == projectID } ?? model.projects.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session")
                .font(.title3.bold())

            LabeledContent("Project") {
                Picker("", selection: $projectID) {
                    ForEach(model.projects) { p in
                        Text(p.name).tag(Optional(p.id))
                    }
                }
                .labelsHidden()
            }

            LabeledContent("Destination") {
                Picker("", selection: $useWorktree) {
                    Text("Repo (current branch)").tag(false)
                    Text("New worktree").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if useWorktree {
                LabeledContent("Branch") {
                    TextField("feat/my-feature", text: $branch)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
                Text("The worktree is created under ~/.trame/worktrees, isolated from the main checkout. The branch is created if it does not exist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Command") {
                TextField("claude (empty = shell)", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    guard let project else { return }
                    let destination: SessionDestination = useWorktree ? .worktree(branch: branch) : .repo
                    let cmd = command
                    Task {
                        await model.createSession(project: project, destination: destination, command: cmd)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(project == nil || (useWorktree && branch.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            projectID = model.createSheetProject?.id ?? model.projects.first?.id
            if let last = project?.lastCommand, !last.isEmpty {
                command = last
            }
        }
    }
}
