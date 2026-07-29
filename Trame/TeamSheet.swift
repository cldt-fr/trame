import SwiftUI

/// The beginner-friendly path to orchestration: pick a project, tick the
/// roles, write the objective, press one button. Trame spawns the whole
/// team (plus a chef) with the mesh fully wired — no manual steps.
struct TeamSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var projectID: UUID?
    @State private var selectedTemplateIDs: Set<UUID> = []
    @State private var objective = ""
    @State private var launching = false

    private var project: Project? {
        model.projects.first { $0.id == projectID } ?? model.projects.first
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Launch an Agent Team")
                    .font(.title2.weight(.semibold))
                Text("One objective, several Claude agents working together — they coordinate over talkie-walkie, no setup needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)

            Form {
                Section("1 · Project") {
                    Picker("Project", selection: $projectID) {
                        ForEach(model.projects) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    .labelsHidden()
                }

                Section {
                    ForEach(model.templates) { template in
                        Toggle(isOn: Binding(
                            get: { selectedTemplateIDs.contains(template.id) },
                            set: { on in
                                if on { selectedTemplateIDs.insert(template.id) } else { selectedTemplateIDs.remove(template.id) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(template.name)
                                    if template.meshEnabled {
                                        Label(template.meshRole, systemImage: "antenna.radiowaves.left.and.right")
                                            .font(.caption2)
                                            .foregroundStyle(Color.teal)
                                    }
                                }
                                Text(roleSummary(template))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                } header: {
                    Text("2 · Team")
                } footer: {
                    Text("A “chef” agent is always added: it receives the objective, splits the work and coordinates the team.")
                }

                Section {
                    TextField("Objective", text: $objective,
                              prompt: Text("e.g. Add email validation to the signup form, with unit tests"),
                              axis: .vertical)
                        .lineLimit(3...6)
                        .labelsHidden()
                } header: {
                    Text("3 · Objective")
                } footer: {
                    Text("Be specific — the quality of the objective drives the quality of the orchestration.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Text(project.map { "The team runs in \($0.name). Watch them in the mesh panel 📡." } ?? "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    launch()
                } label: {
                    if launching {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Launch Team", systemImage: "person.3.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(launching || project == nil || selectedTemplateIDs.isEmpty
                          || objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 500, height: 540)
        .onAppear {
            projectID = model.createSheetProject?.id ?? model.projects.first?.id
            selectedTemplateIDs = Set(model.templates.map(\.id))
        }
    }

    private func roleSummary(_ template: SessionTemplate) -> String {
        let mission = template.mission
            .replacingOccurrences(of: "{objective}", with: "…")
        return mission.isEmpty ? "No mission" : mission
    }

    private func launch() {
        guard let project else { return }
        let chosen = model.templates.filter { selectedTemplateIDs.contains($0.id) }
        let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        launching = true
        Task {
            await model.launchTeam(project: project, templates: chosen, objective: text)
            launching = false
            dismiss()
        }
    }
}
