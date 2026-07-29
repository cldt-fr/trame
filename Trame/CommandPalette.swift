import SwiftUI
import TrameProtocol

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String
    let iconColor: Color
    let action: @MainActor () -> Void
}

/// ⌘K command palette (F10.3): jump to sessions, create sessions, open the
/// library and mesh panels — everything from the keyboard.
struct CommandPalette: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

    private var items: [PaletteItem] {
        var all: [PaletteItem] = []

        for session in model.attentionSessions {
            all.append(PaletteItem(
                id: "attention-\(session.id)",
                title: session.name,
                subtitle: session.attention == "done" ? "Finished — jump to session" : (session.attentionMessage ?? "Needs your attention"),
                icon: session.attention == "done" ? "checkmark.circle.fill" : "bell.badge.fill",
                iconColor: session.attention == "done" ? .blue : .orange
            ) { model.focusSession(session.id) })
        }
        for session in model.sessions where session.attention == nil {
            all.append(PaletteItem(
                id: "session-\(session.id)",
                title: session.name,
                subtitle: (session.cwd as NSString).abbreviatingWithTildeInPath,
                icon: "terminal",
                iconColor: session.isRunning ? .green : .secondary
            ) { model.focusSession(session.id) })
        }
        for project in model.projects {
            all.append(PaletteItem(
                id: "new-\(project.id)",
                title: "New Session in \(project.name)",
                subtitle: nil,
                icon: "plus.circle",
                iconColor: .secondary
            ) {
                model.createSheetProject = project
                model.showCreateSheet = true
            })
        }
        all.append(PaletteItem(id: "mcp", title: "MCP Library", subtitle: nil,
                               icon: "server.rack", iconColor: .secondary) { model.showMCPLibrary = true })
        all.append(PaletteItem(id: "mesh", title: "Mesh Panel", subtitle: nil,
                               icon: "antenna.radiowaves.left.and.right", iconColor: .secondary) { model.showMeshPanel = true })

        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return all }
        let tokens = trimmed.split(separator: " ").map(String.init)
        return all.filter { item in
            let haystack = "\(item.title) \(item.subtitle ?? "")".lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        let filtered = items
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Jump to a session, create, open…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit { execute(filtered) }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                            PaletteRow(item: item, highlighted: index == highlighted)
                                .id(item.id)
                                .onTapGesture {
                                    model.showPalette = false
                                    item.action()
                                }
                                .onHover { if $0 { highlighted = index } }
                        }
                        if filtered.isEmpty {
                            Text("No matches")
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                    }
                }
                .frame(maxHeight: 320)
                .onChange(of: highlighted) { _, index in
                    if filtered.indices.contains(index) {
                        proxy.scrollTo(filtered[index].id)
                    }
                }
            }
        }
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(radius: 24, y: 8)
        .onAppear {
            searchFocused = true
            highlighted = 0
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(0, filtered.count - 1))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            model.showPalette = false
            return .handled
        }
    }

    @MainActor
    private func execute(_ filtered: [PaletteItem]) {
        guard filtered.indices.contains(highlighted) else { return }
        let item = filtered[highlighted]
        model.showPalette = false
        item.action()
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .foregroundStyle(item.iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(highlighted ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
    }
}
