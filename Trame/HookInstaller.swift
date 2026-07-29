import Foundation
import TrameGit

/// Injects the Trame hooks into a session working directory so Claude Code
/// reports attention events (permission requests, end of turn) to the daemon.
///
/// The hooks land in `<cwd>/.claude/settings.local.json` (merged, never
/// overwritten) and the file is added to the repo's `.git/info/exclude` so it
/// never shows up in the user's git status (spec: respect the existing repo).
nonisolated enum HookInstaller {
    /// Marker used to recognize (and not duplicate) Trame-managed hooks.
    private static let marker = "TRAME_SESSION_ID"

    private static let hookCommand = """
    python3 -c "
    import json,sys,os,socket
    try: d=json.load(sys.stdin)
    except Exception: d={}
    sid=os.environ.get('TRAME_SESSION_ID','')
    if sid:
        try:
            s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
            s.connect(os.path.expanduser('~/Library/Application Support/Trame/daemon.sock'))
            s.sendall((json.dumps({'hookEvent':{'sessionID':sid,'event':d.get('hook_event_name',''),'message':d.get('message',''),'tool':d.get('tool_name','')}})+'\\n').encode())
            s.close()
        except Exception: pass
    "
    """

    /// Hook events forwarded to the daemon. Notification/Stop drive the
    /// inbox; the other three drive the live activity display.
    private static let events = ["Notification", "Stop", "UserPromptSubmit", "PreToolUse", "PostToolUse"]

    static func install(in cwd: String) {
        installSettings(in: cwd)
        excludeFromGit(cwd: cwd)
    }

    private static func installSettings(in cwd: String) {
        let dir = (cwd as NSString).appendingPathComponent(".claude")
        let file = (dir as NSString).appendingPathComponent("settings.local.json")

        var settings: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: file),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for event in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let alreadyInstalled = entries.contains { entry in
                let inner = entry["hooks"] as? [[String: Any]] ?? []
                return inner.contains { ($0["command"] as? String)?.contains(marker) == true }
            }
            if !alreadyInstalled {
                entries.append(["hooks": [["type": "command", "command": hookCommand]]])
                hooks[event] = entries
                changed = true
            }
        }
        guard changed else { return }
        settings["hooks"] = hooks

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
        }
    }

    private static func excludeFromGit(cwd: String) {
        guard let gitDir = Git.commonGitDirectory(of: cwd) else { return }
        let excludeFile = (gitDir as NSString).appendingPathComponent("info/exclude")
        let line = ".claude/settings.local.json"
        let existing = (try? String(contentsOfFile: excludeFile, encoding: .utf8)) ?? ""
        guard !existing.components(separatedBy: .newlines).contains(line) else { return }
        try? FileManager.default.createDirectory(
            atPath: (excludeFile as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let updated = existing.isEmpty ? line + "\n" : existing.trimmingCharacters(in: .newlines) + "\n" + line + "\n"
        try? updated.write(toFile: excludeFile, atomically: true, encoding: .utf8)
    }
}
