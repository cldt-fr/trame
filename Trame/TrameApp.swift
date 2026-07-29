import SwiftUI
import TrameDaemon
import TrameProtocol

// The app binary doubles as the daemon (spec §4.2): launched with --daemon it
// runs trame-core headless, so sessions survive quitting the window.
@main
struct TrameLauncher {
    static func main() {
        if CommandLine.arguments.contains("--daemon") {
            Daemon(socketPath: TramePaths.socketPath).run()
        } else {
            TrameApp.main()
        }
    }
}

struct TrameApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .task { await model.start() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session…") {
                    model.showCreateSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command])
                Button("Command Palette") {
                    model.showPalette.toggle()
                }
                .keyboardShortcut("k", modifiers: [.command])
                Button("Launch Agent Team…") {
                    model.showTeamSheet = true
                }
                .keyboardShortcut("t", modifiers: [.command])
                Button("Dispatch an Objective…") {
                    model.showDispatchSheet = true
                }
                .keyboardShortcut("d", modifiers: [.command])
            }
            CommandMenu("Sessions") {
                ForEach(Array(model.sessions.prefix(9).enumerated()), id: \.element.id) { index, session in
                    Button(session.name) {
                        model.focusSession(session.id)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
                }
            }
        }

        // The live 3D open space — one desk per agent.
        Window("Agent Office", id: "office") {
            OfficeView()
                .environmentObject(model)
        }
        .defaultSize(width: 900, height: 560)

        Settings {
            TrameSettings()
                .environmentObject(model)
        }

        // F5.3 — live session state in the menu bar (claude-status-bar
        // style): permission requests win over work, work shows an animated
        // spinner and elapsed time, idle shows the static logo.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    private static let spinnerFrames = ["◐", "◓", "◑", "◒"]

    var body: some View {
        let needsPermission = model.sessions.contains { $0.isRunning && $0.attention == "permission" }
        let working = model.sessions
            .filter { $0.isRunning && $0.activity != nil }
            .min { ($0.activitySince ?? .distantFuture) < ($1.activitySince ?? .distantFuture) }

        if needsPermission {
            // A session awaiting approval is never hidden behind a working one.
            Image(systemName: "bell.badge.fill")
        } else if let working {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 3) {
                    Text(Self.spinnerFrames[Int(context.date.timeIntervalSince1970) % Self.spinnerFrames.count])
                    Text(Self.elapsed(since: working.activitySince, now: context.date))
                        .monospacedDigit()
                }
            }
        } else {
            Image(systemName: "rectangle.grid.2x2")
        }
    }

    static func elapsed(since: Date?, now: Date) -> String {
        guard let since else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let running = model.sessions.filter(\.isRunning)

        if running.isEmpty {
            Text("No active sessions")
        } else {
            // Permission first, then working, then idle/done.
            ForEach(sorted(running)) { session in
                Button {
                    focus(session)
                } label: {
                    Label(title(for: session), systemImage: icon(for: session))
                }
            }
        }
        Divider()
        Button("Open Trame") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Trame (sessions keep running)") {
            NSApp.terminate(nil)
        }
    }

    private func sorted(_ sessions: [SessionInfo]) -> [SessionInfo] {
        sessions.sorted { a, b in
            rank(a) == rank(b) ? a.name < b.name : rank(a) < rank(b)
        }
    }

    private func rank(_ session: SessionInfo) -> Int {
        if session.attention == "permission" { return 0 }
        if session.activity != nil { return 1 }
        if session.attention == "done" { return 2 }
        return 3
    }

    private func title(for session: SessionInfo) -> String {
        if session.attention == "permission" {
            return "\(session.name) — \(session.attentionMessage ?? "needs approval")"
        }
        if let activity = session.activity {
            let time = MenuBarLabel.elapsed(since: session.activitySince, now: Date())
            return "\(session.name) — \(activity) · \(time)"
        }
        if session.attention == "done" {
            return "\(session.name) — finished"
        }
        return "\(session.name) — idle"
    }

    private func icon(for session: SessionInfo) -> String {
        if session.attention == "permission" { return "bell.badge" }
        if session.activity != nil { return "bolt.fill" }
        if session.attention == "done" { return "checkmark.circle" }
        return "terminal"
    }

    private func focus(_ session: SessionInfo) {
        openWindow(id: "main")
        model.focusSession(session.id)
    }
}
