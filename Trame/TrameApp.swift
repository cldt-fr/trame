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

        Settings {
            TrameSettings()
                .environmentObject(model)
        }

        // F5.3 — aggregated state in the menu bar, actionable without the window.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            let waiting = model.attentionSessions.count
            Image(systemName: waiting > 0 ? "bell.badge.fill" : "rectangle.grid.2x2")
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let waiting = model.attentionSessions
        let running = model.sessions.filter(\.isRunning)

        if waiting.isEmpty {
            Text(running.isEmpty ? "No active sessions" : "\(running.count) session(s) running")
        } else {
            Text("\(waiting.count) session(s) need attention")
            ForEach(waiting) { session in
                Button {
                    focus(session)
                } label: {
                    Label(
                        "\(session.name) — \(session.attention == "done" ? "finished" : (session.attentionMessage ?? "needs approval"))",
                        systemImage: session.attention == "done" ? "checkmark.circle" : "bell.badge"
                    )
                }
            }
        }
        Divider()
        ForEach(model.sessions.filter { $0.attention == nil && $0.isRunning }) { session in
            Button {
                focus(session)
            } label: {
                Label(session.name, systemImage: "terminal")
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

    private func focus(_ session: SessionInfo) {
        openWindow(id: "main")
        model.focusSession(session.id)
    }
}
