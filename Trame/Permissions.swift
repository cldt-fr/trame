import Foundation
import TrameProtocol

/// Per-session permission presets (spec F8), applied as claude CLI flags so
/// two sessions on the same checkout can use different presets.
enum PermissionPreset: String, CaseIterable, Identifiable {
    /// Claude Code defaults: everything goes through approval.
    case prudent
    /// Common safe tools pre-approved via --allowedTools; the rest asks.
    case standard
    /// --dangerously-skip-permissions. Recommended inside an isolated
    /// worktree; allowed anywhere with an explicit warning (F8.2).
    case autonomous

    var id: String { rawValue }

    var label: String {
        switch self {
        case .prudent: return "Prudent"
        case .standard: return "Standard"
        case .autonomous: return "Autonomous"
        }
    }

    static let defaultAllowlist = "Read,Grep,Glob,Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(ls:*)"

    /// Flags appended to a `claude` command line.
    func flags(allowlist: String) -> String {
        switch self {
        case .prudent:
            return ""
        case .standard:
            let list = allowlist.trimmingCharacters(in: .whitespaces)
            return list.isEmpty ? "" : "--allowedTools \"\(list)\""
        case .autonomous:
            return "--dangerously-skip-permissions"
        }
    }

    /// Detected from the launch command, so no extra per-session state.
    static func isAutonomous(_ session: SessionInfo) -> Bool {
        session.command.contains { $0.contains("--dangerously-skip-permissions") }
    }
}
