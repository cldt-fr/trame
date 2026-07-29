import Foundation

public struct GitError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }

    public init(message: String) {
        self.message = message
    }
}

public struct Worktree: Equatable, Sendable {
    public let path: String
    public let branch: String?

    public init(path: String, branch: String?) {
        self.path = path
        self.branch = branch
    }
}

/// Thin wrapper around the git CLI. All calls are synchronous; run them off
/// the main thread.
public enum Git {
    @discardableResult
    public static func run(_ args: [String], in directory: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw GitError(message: "git not found: \(error.localizedDescription)")
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message: message.isEmpty ? "git \(args.joined(separator: " ")) failed" : message)
        }
        return String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Root of the repository containing `path`, or nil when not a git repo.
    public static func repositoryRoot(of path: String) -> String? {
        try? run(["rev-parse", "--show-toplevel"], in: path)
    }

    public static func currentBranch(root: String) -> String? {
        try? run(["branch", "--show-current"], in: root)
    }

    /// Common .git directory (shared across worktrees); nil outside a repo.
    public static func commonGitDirectory(of path: String) -> String? {
        guard let dir = try? run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path) else { return nil }
        return dir.isEmpty ? nil : dir
    }

    public static func branchExists(root: String, branch: String) -> Bool {
        (try? run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: root)) != nil
    }

    public static func listWorktrees(root: String) throws -> [Worktree] {
        let output = try run(["worktree", "list", "--porcelain"], in: root)
        var result: [Worktree] = []
        var currentPath: String?
        var currentBranch: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                currentBranch = String(line.dropFirst("branch refs/heads/".count))
            } else if line.isEmpty, let path = currentPath {
                result.append(Worktree(path: path, branch: currentBranch))
                currentPath = nil
                currentBranch = nil
            }
        }
        if let path = currentPath {
            result.append(Worktree(path: path, branch: currentBranch))
        }
        return result
    }

    /// Creates a worktree at `path` on `branch`, creating the branch from the
    /// current HEAD when it does not exist yet.
    public static func addWorktree(root: String, path: String, branch: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        if branchExists(root: root, branch: branch) {
            try run(["worktree", "add", path, branch], in: root)
        } else {
            try run(["worktree", "add", "-b", branch, path], in: root)
        }
    }

    /// Removes a worktree. The branch itself is never deleted (spec F6.3).
    public static func removeWorktree(root: String, path: String, force: Bool) throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(path)
        try run(args, in: root)
    }

    // MARK: - Review (spec F6)

    public struct ChangedFile: Equatable, Sendable, Identifiable {
        public let path: String
        public let additions: Int
        public let deletions: Int
        public let untracked: Bool
        public var id: String { path }

        public init(path: String, additions: Int, deletions: Int, untracked: Bool) {
            self.path = path
            self.additions = additions
            self.deletions = deletions
            self.untracked = untracked
        }
    }

    public static func headCommit(root: String) -> String? {
        try? run(["rev-parse", "HEAD"], in: root)
    }

    /// Everything that changed (committed or not) since `base`, plus
    /// untracked files.
    public static func changedFiles(root: String, base: String) throws -> [ChangedFile] {
        var files: [ChangedFile] = []
        let numstat = try run(["diff", "--numstat", base], in: root)
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            files.append(ChangedFile(
                path: String(parts[2]),
                additions: Int(parts[0]) ?? 0,
                deletions: Int(parts[1]) ?? 0,
                untracked: false
            ))
        }
        let status = try run(["status", "--porcelain"], in: root)
        for line in status.split(separator: "\n") where line.hasPrefix("??") {
            let path = String(line.dropFirst(3))
            if !files.contains(where: { $0.path == path }) {
                files.append(ChangedFile(path: path, additions: 0, deletions: 0, untracked: true))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Unified diff of one file against `base`; untracked files diff against
    /// /dev/null so new content still shows up.
    public static func diff(root: String, base: String, path: String, untracked: Bool) -> String {
        if untracked {
            // --no-index exits 1 when files differ; capture output regardless.
            return (try? run(["diff", "--no-color", "--no-index", "/dev/null", path], in: root))
                ?? (try? String(contentsOfFile: (root as NSString).appendingPathComponent(path), encoding: .utf8))
                .map { $0.split(separator: "\n").map { "+\($0)" }.joined(separator: "\n") }
                ?? ""
        }
        return (try? run(["diff", "--no-color", base, "--", path], in: root)) ?? ""
    }

    /// Stages everything and commits. Throws when there is nothing to commit.
    public static func commitAll(root: String, message: String) throws {
        try run(["add", "-A"], in: root)
        try run(["commit", "-m", message], in: root)
    }

    /// Pushes the current branch, setting the upstream on first push.
    public static func push(root: String) throws {
        guard let branch = currentBranch(root: root), !branch.isEmpty else {
            throw GitError(message: "detached HEAD: no branch to push")
        }
        if (try? run(["rev-parse", "--abbrev-ref", "\(branch)@{upstream}"], in: root)) != nil {
            try run(["push"], in: root)
        } else {
            try run(["push", "-u", "origin", branch], in: root)
        }
    }

    /// Merges `branch` into the branch currently checked out at `root`.
    /// Refuses when the target checkout has local changes (spec F6.3).
    public static func merge(root: String, branch: String) throws {
        let dirty = try run(["status", "--porcelain"], in: root)
        guard dirty.isEmpty else {
            throw GitError(message: "target checkout has uncommitted changes; commit or stash them first")
        }
        do {
            try run(["merge", "--no-ff", branch], in: root)
        } catch {
            _ = try? run(["merge", "--abort"], in: root)
            throw error
        }
    }
}
