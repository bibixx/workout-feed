import SwiftUI
import WorkoutKit

struct HomeView: View {
    let onDisconnect: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ConfigStore.syncIntervalKey) private var syncInterval = ConfigStore.defaultSyncInterval

    @StateObject private var model = SyncModel()
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if model.rows.isEmpty {
                    ContentUnavailableView {
                        Label("No upcoming workouts", systemImage: "calendar.badge.exclamationmark")
                    } description: {
                        Text(model.lastReport?.error ?? "Workouts from your feed will appear here and on your Apple Watch.")
                    } actions: {
                        Button("Sync now") {
                            Task { await model.sync(trigger: "manual") }
                        }
                        .disabled(model.syncing)
                    }
                } else {
                    List {
                        ForEach(sections) { section in
                            Section(section.title) {
                                ForEach(section.rows) { row in
                                    WorkoutRow(row: row)
                                }
                            }
                        }
                        Section {
                        } footer: {
                            statusLine
                        }
                    }
                }
            }
            .navigationTitle("Workouts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        if model.syncing {
                            ProgressView()
                        } else {
                            Image(systemName: "gearshape")
                        }
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .refreshable { await model.sync(trigger: "manual") }
            .task { await initialLoad() }
            .task(id: syncInterval) { await pollLoop() }
            .sheet(isPresented: $showSettings) {
                SettingsView(model: model, onDisconnect: onDisconnect)
            }
        }
    }

    // MARK: - Sections

    private struct DaySection: Identifiable {
        let id: String
        let title: String
        let rows: [SyncModel.Row]
    }

    private var sections: [DaySection] {
        let grouped = Dictionary(grouping: model.rows) { row in
            String(format: "%04d-%02d-%02d", row.date.year ?? 0, row.date.month ?? 0, row.date.day ?? 0)
        }
        return grouped.keys.sorted().map { key in
            let rows = (grouped[key] ?? []).sorted {
                (Calendar.current.date(from: $0.date) ?? .distantFuture) < (Calendar.current.date(from: $1.date) ?? .distantFuture)
            }
            return DaySection(id: key, title: dayTitle(rows.first), rows: rows)
        }
    }

    private func dayTitle(_ row: SyncModel.Row?) -> String {
        guard let row, let date = Calendar.current.date(from: row.date) else { return "Scheduled" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide).day().month())
    }

    private var statusLine: some View {
        Group {
            if let report = model.lastReport {
                if let error = report.error {
                    Text("Last sync \(report.date.formatted(.relative(presentation: .named))) — \(error)")
                } else {
                    Text("Synced \(report.date.formatted(.relative(presentation: .named))) · \(report.onWatch) on watch (+\(report.added) −\(report.removed))")
                }
            } else {
                Text("Pull to refresh.")
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func initialLoad() async {
        await model.bootstrapFromScheduler()
        SyncEngine.scheduleBackgroundRefresh()
        // Auto-sync on launch unless we synced recently (don't churn on every open).
        // Capped at 30 min so a long interval (e.g. daily) still gets a fresh open.
        // Never throttle when the watch is empty — right after connect there's nothing
        // scheduled yet and a stale pre-connect report must not suppress the first sync.
        let staleAfter = min(syncInterval, 30 * 60)
        if !model.rows.isEmpty, let last = model.lastReport?.date, Date().timeIntervalSince(last) < staleAfter { return }
        await model.sync(trigger: "launch")
    }

    /// Foreground polling on the configured interval while the app is open. This is what makes
    /// the short debug interval real — iOS background refresh never fires that often.
    @MainActor
    private func pollLoop() async {
        let interval = max(syncInterval, 30)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled { return }
            guard scenePhase == .active, !showSettings else { continue }
            await model.sync(trigger: "auto")
        }
    }
}

private struct WorkoutRow: View {
    let row: SyncModel.Row

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .strikethrough(isComplete)
                subtitle
            }
            Spacer()
            trailing
        }
    }

    private var isComplete: Bool {
        if case .onWatch(let complete) = row.state { return complete }
        return false
    }

    @ViewBuilder
    private var subtitle: some View {
        switch row.state {
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        case .skipped(let reason):
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
        default:
            if let date = Calendar.current.date(from: row.date) {
                Text(date.formatted(.dateTime.hour().minute()))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.state {
        case .loading:
            ProgressView()
        case .onWatch(let complete):
            if complete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "applewatch.and.arrow.forward")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }
}
