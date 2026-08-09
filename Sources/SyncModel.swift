import Foundation
import SwiftUI
import WorkoutKit

/// Foreground-facing sync state: the row list the home screen renders, updated live
/// by SyncEngine events as each workout resolves. Background refresh bypasses this
/// and uses SyncEngine directly.
@MainActor
final class SyncModel: ObservableObject {
    struct Row: Identifiable {
        let id: String
        var title: String
        var symbol: String
        var date: DateComponents
        var state: SyncItemState
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var syncing = false
    @Published private(set) var lastReport: SyncReport? = ReportStore.last

    /// Show what's already on the watch instantly on launch, before the first sync lands.
    func bootstrapFromScheduler() async {
        guard rows.isEmpty else { return }
        let scheduled = await SyncEngine.scheduledPlans()
        rows = scheduled.map { entry in
            Row(
                id: "scheduled-\(entry.plan.id.uuidString)-\(componentsKey(entry.date))",
                title: entry.plan.displayTitle,
                symbol: entry.plan.activitySymbol,
                date: entry.date,
                state: .onWatch(complete: entry.complete)
            )
        }
    }

    func sync(trigger: String) async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        let report = await SyncEngine.sync(trigger: trigger) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        lastReport = report
    }

    private func handle(_ event: SyncEvent) {
        switch event {
        case .manifestLoaded(let seeds):
            // Carry over resolved state for rows that are already known (same id), so a
            // re-sync doesn't flash everything back to spinners.
            let previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            rows = seeds.map { seed in
                if let existing = previous[seed.uiKey] {
                    var row = existing
                    row.date = seed.date
                    return row
                }
                return Row(id: seed.uiKey, title: seed.title, symbol: "figure.mixed.cardio", date: seed.date, state: .loading)
            }
        case .itemUpdate(let uiKey, let state, let title, let symbol):
            guard let index = rows.firstIndex(where: { $0.id == uiKey }) else { return }
            rows[index].state = state
            if let title { rows[index].title = title }
            if let symbol { rows[index].symbol = symbol }
        }
    }

    private func componentsKey(_ components: DateComponents) -> String {
        String(
            format: "%04d-%02d-%02dT%02d:%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0
        )
    }
}
