import AppKit
import SwiftTerm
import SwiftUI
import TrameClient
import TrameProtocol

/// SwiftTerm terminal bound to a daemon session through an AttachStream.
struct TerminalHostView: NSViewRepresentable {
    @EnvironmentObject private var model: AppModel
    let sessionID: String

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionID: sessionID)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.configureNativeColors()
        context.coordinator.model = model
        context.coordinator.bind(view: view, socketPath: model.client.socketPath)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.model = model
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let sessionID: String
        weak var model: AppModel?
        private var stream: AttachStream?
        private weak var terminalView: TerminalView?

        init(sessionID: String) {
            self.sessionID = sessionID
        }

        func bind(view: TerminalView, socketPath: String) {
            terminalView = view
            view.terminalDelegate = self

            let stream = AttachStream()
            self.stream = stream
            stream.onData = { [weak self] data in
                DispatchQueue.main.async {
                    self?.terminalView?.feed(byteArray: ArraySlice(data))
                }
            }
            do {
                try stream.attach(socketPath: socketPath, sessionID: sessionID, replay: true)
            } catch {
                view.feed(text: "⚠️  attach impossible : \(error.localizedDescription)\r\n")
            }
        }

        nonisolated func detach() {
            Task { @MainActor in
                self.stream?.closeStream()
                self.stream = nil
            }
        }

        // MARK: - TerminalViewDelegate

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let payload = Data(data)
            Task { @MainActor in
                self.stream?.send(payload)
            }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in
                self.model?.resize(self.sessionID, cols: newCols, rows: newRows)
            }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}

        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        nonisolated func scrolled(source: TerminalView, position: Double) {}

        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        }

        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }

        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        nonisolated func bell(source: TerminalView) {}

        nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}
