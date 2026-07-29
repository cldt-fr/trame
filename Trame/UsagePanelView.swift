import Charts
import SwiftUI
import TrameUsage

/// Usage & estimated costs across all accounts (F7).
struct UsagePanelSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dailyCostLimit") private var dailyCostLimit = 0.0

    @State private var loading = true
    @State private var days: [(day: Date, totals: UsageTotals)] = []
    @State private var models: [(model: String, totals: UsageTotals)] = []
    @State private var todayCost = 0.0
    @State private var weekCost = 0.0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Usage")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("Estimated API-equivalent costs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            if loading {
                Spacer()
                ProgressView("Reading transcripts…")
                Spacer()
            } else {
                content
            }

            Divider()
            HStack(spacing: 8) {
                Text("Daily alert")
                    .font(.caption)
                TextField("0 = off", value: $dailyCostLimit, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("$/day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 480)
        .task { await load() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    statTile("Today", todayCost)
                    statTile("Last 7 days", weekCost)
                    statTile("Last 14 days", days.reduce(0) { $0 + $1.totals.costUSD })
                }

                if !days.isEmpty {
                    Chart(days, id: \.day) { entry in
                        BarMark(
                            x: .value("Day", entry.day, unit: .day),
                            y: .value("Cost", entry.totals.costUSD)
                        )
                        .foregroundStyle(Color.accentColor)
                        .cornerRadius(3)
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let v = value.as(Double.self) {
                                    Text("$\(v, specifier: "%.0f")")
                                }
                            }
                        }
                    }
                    .frame(height: 140)
                }

                if !models.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("By model (14 days)")
                            .font(.headline)
                        ForEach(models, id: \.model) { entry in
                            HStack {
                                Text(entry.model)
                                    .font(.caption.monospaced())
                                Spacer()
                                Text(Self.tokens(entry.totals))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "$%.2f", entry.totals.costUSD))
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                }

                if days.isEmpty {
                    ContentUnavailableView(
                        "No usage found",
                        systemImage: "chart.bar",
                        description: Text("No Claude Code transcripts in the last 14 days.")
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private func statTile(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "$%.2f", value))
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private static func tokens(_ t: UsageTotals) -> String {
        let total = t.inputTokens + t.outputTokens + t.cacheCreationTokens + t.cacheReadTokens
        if total >= 1_000_000 { return String(format: "%.1fM tok", Double(total) / 1_000_000) }
        return String(format: "%.0fK tok", Double(total) / 1_000)
    }

    private func load() async {
        let dirs = model.usageConfigDirs
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -13, to: calendar.startOfDay(for: Date()))!
        let result = await Task.detached { () -> ([(Date, UsageTotals)], [(String, UsageTotals)]) in
            let events = UsageScanner.scan(configDirs: dirs, since: start)
            return (UsageAggregator.byDay(events), UsageAggregator.byModel(events))
        }.value
        days = result.0
        models = result.1
        let today = calendar.startOfDay(for: Date())
        todayCost = days.first { $0.day == today }?.totals.costUSD ?? 0
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today)!
        weekCost = days.filter { $0.day >= weekStart }.reduce(0) { $0 + $1.totals.costUSD }
        loading = false
    }
}
