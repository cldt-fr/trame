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
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task { await model.start() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Nouvelle session…") {
                    model.showCreateSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}
