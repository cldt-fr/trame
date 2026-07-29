import SwiftUI
import TrameGit
import TrameProtocol

/// Native review of a session's work (F6): what changed since the session
/// started, per-file diffs, and commit / push / PR / merge actions.
struct ChangesView: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionInfo

    @State private var files: [Git.ChangedFile] = []
    @State private var selectedPath: String?
    @State private var diffText = ""
    @State private var commitMessage = ""
    @State private var busy = false
    @State private var actionError: String?
    @State private var actionInfo: String?
    @State private var showMergeConfirm = false
    @State private var loaded = false

    private var root: String { session.cwd }
    private var base: String { model.baseCommit(for: session) }
    private var isWorktree: Bool { model.isWorktreeSession(session) }

    var body: some View {
        VStack(spacing: 0) {
            if loaded && files.isEmpty {
                ContentUnavailableView(
                    "No changes",
                    systemImage: "checkmark.seal",
                    description: Text("Nothing changed since this session started.")
                )
                .frame(maxHeight: .infinity)
            } else {
                HSplitView {
                    fileList
                        .frame(minWidth: 220, maxWidth: 340)
                    DiffTextView(diff: diffText)
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            actionBar
        }
        .task(id: session.id) { await reload() }
        .onChange(of: selectedPath) { _, path in
            Task { await loadDiff(path: path) }
        }
        .confirmationDialog(
            "Merge “\(session.name)” into the main checkout?",
            isPresented: $showMergeConfirm
        ) {
            Button("Merge") { Task { await merge() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs git merge --no-ff of this worktree's branch into the branch checked out at the project root. The branch is kept.")
        }
    }

    private var fileList: some View {
        List(files, selection: $selectedPath) { file in
            HStack(spacing: 6) {
                Text((file.path as NSString).lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                if file.untracked {
                    Text("new")
                        .font(.caption2)
                        .foregroundStyle(Color.green)
                } else {
                    Text("+\(file.additions)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.green)
                    Text("−\(file.deletions)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.red)
                }
            }
            .help(file.path)
            .tag(file.path)
        }
        .listStyle(.inset)
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Commit message", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
                Button("Commit All") { Task { await commit() } }
                    .disabled(busy || commitMessage.trimmingCharacters(in: .whitespaces).isEmpty || files.isEmpty)
                Button("Push") { Task { await push() } }
                    .disabled(busy)
                Button("Create PR") { Task { await createPR() } }
                    .disabled(busy)
                if isWorktree {
                    Button("Merge…") { showMergeConfirm = true }
                        .disabled(busy)
                        .help("Merge this worktree's branch into the project root checkout")
                }
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(busy)
                .help("Refresh")
            }
            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .textSelection(.enabled)
            } else if let actionInfo {
                Text(actionInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
    }

    // MARK: - Data

    private func reload() async {
        let root = root, base = base
        let result = await Task.detached { try? Git.changedFiles(root: root, base: base) }.value
        files = result ?? []
        loaded = true
        if selectedPath == nil || !files.contains(where: { $0.path == selectedPath }) {
            selectedPath = files.first?.path
        }
        await loadDiff(path: selectedPath)
        if commitMessage.isEmpty {
            commitMessage = "\(session.name): "
        }
    }

    private func loadDiff(path: String?) async {
        guard let path, let file = files.first(where: { $0.path == path }) else {
            diffText = ""
            return
        }
        let root = root, base = base
        diffText = await Task.detached {
            Git.diff(root: root, base: base, path: file.path, untracked: file.untracked)
        }.value
    }

    // MARK: - Actions

    private func runAction(_ label: String, _ work: @escaping @Sendable () throws -> String?) async {
        busy = true
        actionError = nil
        actionInfo = nil
        let result: Result<String?, Error> = await Task.detached {
            do { return .success(try work()) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let info):
            actionInfo = info ?? "\(label) ✓"
        case .failure(let error):
            actionError = "\(label) failed: \(error.localizedDescription)"
        }
        busy = false
        await reload()
    }

    private func commit() async {
        let root = root, message = commitMessage
        await runAction("Commit") {
            try Git.commitAll(root: root, message: message)
            return "Committed ✓"
        }
        commitMessage = ""
    }

    private func push() async {
        let root = root
        await runAction("Push") {
            try Git.push(root: root)
            return "Pushed ✓"
        }
    }

    private func createPR() async {
        let root = root
        await runAction("Create PR") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "gh pr create --fill 2>&1"]
            process.currentDirectoryURL = URL(fileURLWithPath: root)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw GitError(message: output.isEmpty ? "gh pr create failed (is the GitHub CLI installed?)" : output)
            }
            if let url = output.split(separator: "\n").last.flatMap({ URL(string: String($0)) }) {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                return "PR created: \(url.absoluteString)"
            }
            return output
        }
    }

    private func merge() async {
        let worktreeRoot = root
        guard let projectRoot = model.project(for: session)?.root,
              let branch = await Task.detached(operation: { Git.currentBranch(root: worktreeRoot) }).value else {
            actionError = "Could not resolve the worktree branch."
            return
        }
        await runAction("Merge") {
            try Git.merge(root: projectRoot, branch: branch)
            return "Merged \(branch) ✓ — you can now delete the session and its worktree."
        }
    }
}

/// Minimal unified-diff renderer: green additions, red deletions, dimmed
/// hunk headers, selectable monospaced text.
struct DiffTextView: View {
    let diff: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(String(line))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color(for: line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(for: line))
                }
            }
            .padding(8)
            .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func color(for line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
            return .secondary
        }
        if line.hasPrefix("@@") { return .blue }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return .primary
    }

    private func background(for line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return Color.green.opacity(0.08) }
        if line.hasPrefix("-") { return Color.red.opacity(0.08) }
        return .clear
    }
}
