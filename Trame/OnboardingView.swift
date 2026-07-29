import SwiftUI

/// First-launch onboarding (spec F10.5): welcome, live requirement checks,
/// first project, core concepts, and a guided first launch.
struct OnboardingSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboardingDone") private var onboardingDone = false

    @State private var page = 0
    private let pageCount = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: requirements
                case 2: firstProject
                case 3: concepts
                default: finish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)

            Divider()
            HStack {
                Button("Skip") {
                    complete()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                if page < pageCount - 1 {
                    Button("Continue") { page += 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start Using Trame") { complete() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 500)
        .interactiveDismissDisabled(!onboardingDone)
    }

    private func complete() {
        onboardingDone = true
        dismiss()
    }

    // MARK: - Page 1 · Welcome

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.3x3.topleft.filled")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Welcome to Trame")
                .font(.largeTitle.weight(.semibold))
            Text("Run several Claude Code agents in parallel — on your repos, in isolated worktrees, talking to each other — and stay in control from one calm window.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("Your sessions keep running even if you quit the app.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Page 2 · Requirements

    private struct Requirement: Identifiable {
        let id: String
        let name: String
        let detail: String
        let optional: Bool
        var status: Bool?
    }

    private var requirements: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(icon: "checklist", title: "Requirements",
                   subtitle: "Trame drives tools you already have. Let's check they are on your PATH.")
            VStack(spacing: 10) {
                ForEach(requirementChecks) { req in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(req.status == nil ? Color.secondary.opacity(0.3)
                                  : (req.status == true ? Color.green : (req.optional ? Color.orange : Color.red)))
                            .frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 6) {
                                Text(req.name).font(.body.weight(.medium))
                                if req.optional {
                                    Text("optional")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Text(req.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if req.status == nil { ProgressView().controlSize(.small) }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if requirementChecks.first(where: { $0.id == "claude" })?.status == false {
                Label("Install Claude Code first: https://claude.com/claude-code", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Color.orange)
            }
        }
        .task { await runChecks() }
    }

    @State private var requirementChecks: [Requirement] = [
        Requirement(id: "claude", name: "Claude Code", detail: "The claude CLI — the agents Trame runs", optional: false, status: nil),
        Requirement(id: "git", name: "git", detail: "Projects, worktrees and the review tab", optional: false, status: nil),
        Requirement(id: "npx", name: "Node.js (npx)", detail: "Only needed for the talkie-walkie mesh", optional: true, status: nil),
        Requirement(id: "gh", name: "GitHub CLI (gh)", detail: "Only needed to create pull requests", optional: true, status: nil),
    ]

    private func runChecks() async {
        for index in requirementChecks.indices where requirementChecks[index].status == nil {
            let tool = requirementChecks[index].id
            let found = await Task.detached { () -> Bool in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", "command -v \(tool)"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            }.value
            requirementChecks[index].status = found
        }
    }

    // MARK: - Page 3 · First project

    private var firstProject: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(icon: "folder.badge.plus", title: "Add your first project",
                   subtitle: "A project is simply a git repository. Sessions and agent teams run inside it.")
            if model.projects.isEmpty {
                Button {
                    pickProject()
                } label: {
                    Label("Choose a git repository…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.projects) { project in
                        Label {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(project.name).font(.body.weight(.medium))
                                Text((project.root as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.green)
                        }
                    }
                    Button("Add another…") { pickProject() }
                        .controlSize(.small)
                }
            }
            Text("You can add more projects anytime from the bottom of the sidebar.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    private func pickProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.message = "Choose a git repository"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.addProject(from: url) }
        }
    }

    // MARK: - Page 4 · Concepts

    private var concepts: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(icon: "lightbulb", title: "Three things to know",
                   subtitle: "Everything else follows from these.")
            conceptCard(icon: "terminal", color: .accentColor,
                        title: "Sessions",
                        text: "A session is one Claude agent in a folder. ⌘N to create one — on the repo, or on an isolated worktree to run several agents on the same project without conflicts.")
            conceptCard(icon: "person.3.fill", color: .teal,
                        title: "Agent teams",
                        text: "⌘T launches a whole team on one objective: Dev, Reviewer, Tester and a Chef who splits the work and coordinates them over the talkie-walkie mesh. Watch them talk in the mesh panel 📡.")
            conceptCard(icon: "bell.badge.fill", color: .orange,
                        title: "The inbox",
                        text: "When an agent needs you — a permission, a finished task — it shows up at the top of the sidebar, in the menu bar, and as a notification. You never have to babysit terminals.")
        }
    }

    private func conceptCard(icon: String, color: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Page 5 · Finish

    private var finish: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text("You're ready")
                .font(.largeTitle.weight(.semibold))
            Text("Start small: one session on one project. Or go straight for the magic — a full agent team on one objective.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                Button {
                    complete()
                    model.createSheetProject = model.projects.first
                    model.showCreateSheet = true
                } label: {
                    Label("First Session", systemImage: "terminal")
                }
                .disabled(model.projects.isEmpty)
                Button {
                    complete()
                    model.showTeamSheet = true
                } label: {
                    Label("Launch an Agent Team", systemImage: "person.3.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.projects.isEmpty)
            }
            Text("⌘K opens the command palette — everything is in there.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    private func header(icon: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.title.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
