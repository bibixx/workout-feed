import HealthKit
import SwiftUI
import UIKit
import WorkoutKit

struct DebugView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ConfigStore.debugUnlockedKey) private var debugUnlocked = false
    @AppStorage(ConfigStore.syncIntervalKey) private var syncInterval = ConfigStore.defaultSyncInterval

    @State private var scheduled: [ScheduledWorkoutPlan] = []
    @State private var reports: [SyncReport] = []
    @State private var message: String?
    @State private var busy = false

    private let config = ConfigStore.load()

    var body: some View {
        Form {
            Section("Configuration") {
                LabeledContent("Feed URL", value: config?.feedURL ?? "—")
                LabeledContent("Manifest", value: config.flatMap { FeedClient.manifestURL(from: $0.feedURL)?.absoluteString } ?? "—")
                LabeledContent("Authorization", value: masked(config?.authHeader))
                LabeledContent("Interval", value: "\(Int(ConfigStore.syncInterval))s")
                LabeledContent("BG task", value: SyncEngine.refreshTaskID)
            }

            Section {
                Button("Sync now") {
                    Task {
                        await run {
                            let report = await SyncEngine.sync(trigger: "debug")
                            return report.error ?? "Synced: +\(report.added) −\(report.removed) =\(report.kept) kept."
                        }
                    }
                }
                Button("Copy manifest JSON") {
                    Task { await copyManifest() }
                }
                Button("Schedule test workout (+15 min)") {
                    Task { await scheduleTest() }
                }
                Button("Clear all scheduled", role: .destructive) {
                    Task {
                        await run {
                            let count = await SyncEngine.clearAllScheduled()
                            return "Removed \(count)."
                        }
                    }
                }
                Button("Hide debug menu", role: .destructive) {
                    hideDebug()
                }
            } header: {
                Text("Actions")
            } footer: {
                if let message {
                    Text(message)
                }
            }

            Section("Scheduled on watch (\(scheduled.count))") {
                if scheduled.isEmpty {
                    Text("Nothing scheduled.").foregroundStyle(.secondary)
                }
                ForEach(scheduled, id: \.self) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.plan.displayTitle)
                            .font(.subheadline)
                        Text("\(item.plan.id.uuidString.prefix(8)) · \(componentsLabel(item.date)) · \(item.complete ? "complete" : "pending")")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Sync history (\(reports.count))") {
                if reports.isEmpty {
                    Text("No syncs yet.").foregroundStyle(.secondary)
                }
                ForEach(reports) { report in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(report.trigger) · \(report.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline)
                        if let error = report.error {
                            Text(error)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.red)
                        } else {
                            Text("+\(report.added) −\(report.removed) =\(report.kept) kept · \(report.onWatch) on watch")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if !report.skipped.isEmpty {
                            Text("skipped: \(report.skipped.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if let notes = report.notes, !notes.isEmpty {
                            Text(notes.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .navigationTitle("Debug")
        .task { await reload() }
        .refreshable { await reload() }
        .disabled(busy)
    }

    /// Re-locks the debug menu (5 taps on the Version row bring it back). Resets the
    /// interval when it's on the debug-only 30s value so no hidden setting stays active.
    private func hideDebug() {
        if syncInterval < 15 * 60 {
            syncInterval = ConfigStore.defaultSyncInterval
        }
        debugUnlocked = false
        dismiss()
    }

    private func masked(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "none" }
        return "set (\(value.count) chars)"
    }

    private func componentsLabel(_ components: DateComponents) -> String {
        String(
            format: "%04d-%02d-%02d %02d:%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0
        )
    }

    @MainActor
    private func reload() async {
        scheduled = await SyncEngine.scheduledPlans()
        reports = ReportStore.all()
    }

    @MainActor
    private func run(_ action: () async -> String) async {
        busy = true
        defer { busy = false }
        message = await action()
        await reload()
    }

    @MainActor
    private func copyManifest() async {
        guard let config else {
            message = "Not configured."
            return
        }
        do {
            let (_, _, raw) = try await FeedClient.fetchManifest(config: config)
            UIPasteboard.general.string = String(data: raw, encoding: .utf8) ?? ""
            message = "Manifest copied (\(raw.count) bytes)."
        } catch {
            message = "⚠️ \(error.localizedDescription)"
        }
    }

    @MainActor
    private func scheduleTest() async {
        await run {
            let step = IntervalStep(.work, goal: .time(1, .minutes))
            let block = IntervalBlock(steps: [step], iterations: 1)
            let custom = CustomWorkout(activity: .running, location: .outdoor, displayName: "Debug Test", blocks: [block])
            let plan = WorkoutPlan(.custom(custom))

            let state = await WorkoutScheduler.shared.requestAuthorization()
            guard state == .authorized else { return "Not authorized (\(state))." }

            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: Date().addingTimeInterval(15 * 60))
            await WorkoutScheduler.shared.schedule(plan, at: components)
            return "Test workout scheduled for ~15 min from now."
        }
    }
}
