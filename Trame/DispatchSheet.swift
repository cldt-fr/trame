import SwiftUI
import TrameProtocol

/// V2 orchestration entry point: send an objective to running sessions, or
/// spawn a mesh "chef" session that coordinates the team over talkie-walkie.
struct DispatchSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Mode {
        case sessions, chef
    }

    @State private var mode: Mode = .sessions
    @State private var objective = ""
    @State private var targetIDs: Set<String> = []
    @State private var chefProjectID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Dispatch an Objective")
                    .font(.title2.weight(.semibold))
                Spacer()
                Picker("", selection: $mode) {
                    Text("To sessions").tag(Mode.sessions)
                    Text("Via a chef").tag(Mode.chef)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)

            Form {
                Section("Objective") {
                    TextField("Objective", text: $objective,
                              prompt: Text("e.g. Add rate limiting to the API, with tests"),
                              axis: .vertical)
                        .lineLimit(3...6)
                        .labelsHidden()
                }

                switch mode {
                case .sessions:
                    Section {
                        let running = model.sessions.filter(\.isRunning)
                        if running.isEmpty {
                            Text("No running sessions.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(running) { session in
                            Toggle(isOn: Binding(
                                get: { targetIDs.contains(session.id) },
                                set: { on in
                                    if on { targetIDs.insert(session.id) } else { targetIDs.remove(session.id) }
                                }
                            )) {
                                HStack(spacing: 6) {
                                    Text(session.name)
                                    if let role = model.meshMember(for: session.id)?.role {
                                        Label(role, systemImage: "antenna.radiowaves.left.and.right")
                                            .font(.caption2)
                                            .foregroundStyle(Color.teal)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    } header: {
                        Text("Target sessions")
                    } footer: {
                        Text("The objective is typed into each selected session, as if you had written it there.")
                    }

                case .chef:
                    Section {
                        Picker("Project", selection: $chefProjectID) {
                            ForEach(model.projects) { p in
                                Text(p.name).tag(Optional(p.id))
                            }
                        }
                    } header: {
                        Text("Chef session")
                    } footer: {
                        Text(model.meshMembers.isEmpty
                             ? "⚠️ No mesh members yet — the chef needs teammates. Create sessions with “Join talkie-walkie mesh” first (e.g. the Dev / Reviewer / Tester templates)."
                             : "A new “chef” session joins the mesh (\(model.meshMembers.map(\.role).joined(separator: ", "))), receives the objective as its mission, delegates tasks over talkie-walkie and follows up until done.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .chef ? "Create Chef & Dispatch" : "Dispatch") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(disabled)
            }
            .padding(16)
        }
        .frame(width: 480, height: 460)
        .onAppear {
            chefProjectID = model.createSheetProject?.id ?? model.projects.first?.id
            if let selected = model.selectedSession, selected.isRunning {
                targetIDs = [selected.id]
            }
        }
    }

    private var disabled: Bool {
        let noObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch mode {
        case .sessions: return noObjective || targetIDs.isEmpty
        case .chef: return noObjective || chefProjectID == nil || model.meshMembers.isEmpty
        }
    }

    private func run() {
        let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .sessions:
            let ids = Array(targetIDs)
            Task { await model.dispatch(objective: text, to: ids) }
        case .chef:
            if let project = model.projects.first(where: { $0.id == chefProjectID }) {
                Task { await model.createChefSession(project: project, objective: text) }
            }
        }
        dismiss()
    }
}
