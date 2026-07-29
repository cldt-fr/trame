import Foundation
import Testing
@testable import TrameGit

private func makeTempRepo() throws -> String {
    let dir = NSTemporaryDirectory() + "trame-git-test-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try Git.run(["init", "-b", "main"], in: dir)
    try "hello".write(toFile: dir + "/README.md", atomically: true, encoding: .utf8)
    try Git.run(["add", "."], in: dir)
    try Git.run(["-c", "user.name=test", "-c", "user.email=test@test", "commit", "-m", "init"], in: dir)
    // git init may return a symlinked path on macOS (/var vs /private/var).
    return Git.repositoryRoot(of: dir) ?? dir
}

@Suite struct GitTests {
    @Test func repoDetection() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        #expect(Git.repositoryRoot(of: repo) == repo)
        #expect(Git.currentBranch(root: repo) == "main")
        #expect(Git.repositoryRoot(of: NSTemporaryDirectory()) == nil)
    }

    @Test func worktreeLifecycle() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let wtPath = repo + "-wt"
        defer { try? FileManager.default.removeItem(atPath: wtPath) }

        // Create on a new branch.
        try Git.addWorktree(root: repo, path: wtPath, branch: "feat/test")
        #expect(FileManager.default.fileExists(atPath: wtPath + "/README.md"))
        #expect(Git.branchExists(root: repo, branch: "feat/test"))

        let worktrees = try Git.listWorktrees(root: repo)
        #expect(worktrees.count == 2)
        #expect(worktrees.contains { $0.branch == "feat/test" })

        // Remove keeps the branch (spec F6.3).
        try Git.removeWorktree(root: repo, path: wtPath, force: true)
        #expect(try Git.listWorktrees(root: repo).count == 1)
        #expect(Git.branchExists(root: repo, branch: "feat/test"))

        // Re-adding on the now-existing branch works too.
        try Git.addWorktree(root: repo, path: wtPath, branch: "feat/test")
        #expect(try Git.listWorktrees(root: repo).count == 2)
        try Git.removeWorktree(root: repo, path: wtPath, force: true)
    }
}
