import Foundation

public struct GitError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
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
}
