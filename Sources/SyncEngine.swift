import BackgroundTasks
import Foundation
import HealthKit
import WorkoutKit

struct SyncReport: Codable, Identifiable {
    let date: Date
    let trigger: String
    let onWatch: Int
    let added: Int
    let removed: Int
    let kept: Int
    let skipped: [String]
    let error: String?
    // Added after v0.2 — optional so older persisted reports still decode.
    let failed: Int?
    let notes: [String]?

    var id: Date { date }
}

enum ReportStore {
    private static let key = "syncReports"
    private static let maxCount = 20

    static func all() -> [SyncReport] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SyncReport].self, from: data)) ?? []
    }

    static var last: SyncReport? { all().first }

    static func append(_ report: SyncReport) {
        var reports = all()
        reports.insert(report, at: 0)
        if reports.count > maxCount { reports = Array(reports.prefix(maxCount)) }
        if let data = try? JSONEncoder().encode(reports) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Progress events (drive the UI's per-row loading states)

enum SyncItemState: Equatable, Sendable {
    case loading
    case onWatch(complete: Bool)
    case failed(String)
    case skipped(String)
}

struct SyncRowSeed: Sendable {
    let uiKey: String
    let title: String
    let date: DateComponents
}

enum SyncEvent: Sendable {
    case manifestLoaded([SyncRowSeed])
    case itemUpdate(uiKey: String, state: SyncItemState, title: String?, symbol: String?)
}

enum SyncError: LocalizedError {
    case notAuthorized(WorkoutScheduler.AuthorizationState)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Workout scheduling isn't allowed. Grant permission when prompted."
        }
    }
}

enum SyncEngine {
    static let refreshTaskID = "dev.bibixx.workout-feed.refresh"
    static let defaultHour = 7

    static func uiKey(_ item: FeedItem) -> String {
        "\(item.url)|\(item.date)"
    }

    // MARK: - Sync (never throws; failures land in the report)

    @discardableResult
    static func sync(trigger: String, onEvent: (@Sendable (SyncEvent) -> Void)? = nil) async -> SyncReport {
        let report: SyncReport
        do {
            report = try await performSync(trigger: trigger, onEvent: onEvent)
        } catch {
            let onWatch = await WorkoutScheduler.shared.scheduledWorkouts.count
            report = SyncReport(
                date: Date(), trigger: trigger, onWatch: onWatch,
                added: 0, removed: 0, kept: 0, skipped: [],
                error: error.localizedDescription, failed: nil, notes: nil
            )
        }
        ReportStore.append(report)
        return report
    }

    private enum OutcomeKind: Sendable {
        case kept
        case added
        case failed
        case skipped
    }

    private struct ItemOutcome: Sendable {
        let label: String
        let kind: OutcomeKind
        let matched: ScheduledWorkoutPlan?
        let note: String?
    }

    private static func performSync(trigger: String, onEvent: (@Sendable (SyncEvent) -> Void)?) async throws -> SyncReport {
        guard let config = ConfigStore.load() else { throw FeedError.notConfigured }
        let (manifest, manifestURL, _) = try await FeedClient.fetchManifest(config: config)

        // Dedupe (same file + date twice) before anything else, so row ids are unique.
        var seen = Set<String>()
        var items: [FeedItem] = []
        var duplicateNotes: [String] = []
        for item in manifest.workouts {
            if seen.insert(uiKey(item)).inserted {
                items.append(item)
            } else {
                duplicateNotes.append("\(FeedClient.label(of: item)) — duplicate")
            }
        }

        // The UI can render the full list (as loading) the moment the manifest is in.
        onEvent?(.manifestLoaded(items.map { item in
            SyncRowSeed(uiKey: uiKey(item), title: item.title ?? "Workout", date: dateComponents(fromISO: item.date))
        }))

        let state = await WorkoutScheduler.shared.requestAuthorization()
        guard state == .authorized else {
            // Without authorization the seeded rows would spin forever — resolve them
            // all to a visible "can't schedule" state instead.
            for item in items {
                onEvent?(.itemUpdate(uiKey: uiKey(item), state: .skipped("can't schedule — no permission"), title: nil, symbol: nil))
            }
            throw SyncError.notAuthorized(state)
        }

        let existing = await WorkoutScheduler.shared.scheduledWorkouts
        var existingByKey: [PlanKey: ScheduledWorkoutPlan] = [:]
        for scheduled in existing {
            existingByKey[PlanKey(planID: scheduled.plan.id, date: scheduled.date)] = scheduled
        }
        let existingIndex = existingByKey

        // Fetch, decode, and schedule every item CONCURRENTLY — each row resolves as it lands.
        var outcomes: [ItemOutcome] = []
        await withTaskGroup(of: ItemOutcome.self) { group in
            for item in items {
                group.addTask {
                    await processItem(item, manifestURL: manifestURL, config: config, existingByKey: existingIndex, onEvent: onEvent)
                }
            }
            for await outcome in group {
                outcomes.append(outcome)
            }
        }

        let kept = outcomes.filter { $0.kind == .kept }.count
        let added = outcomes.filter { $0.kind == .added }.count
        let failedCount = outcomes.filter { $0.kind == .failed }.count
        var skipped = outcomes.compactMap { $0.kind == .skipped ? $0.note : nil }
        skipped.append(contentsOf: duplicateNotes)
        var notes: [String] = []

        // Prune entries that vanished from the feed — but only when this run saw the whole
        // picture. With fetch failures we can't tell "removed from feed" from "temporarily
        // unreadable", so we keep everything rather than over-delete.
        var removed = 0
        if failedCount == 0 {
            let handled = Set(outcomes.compactMap { $0.matched })
            let stale = existing.filter { !handled.contains($0) }
            await withTaskGroup(of: Void.self) { group in
                for entry in stale {
                    group.addTask { await WorkoutScheduler.shared.remove(entry.plan, at: entry.date) }
                }
            }
            removed = stale.count
        } else if !existing.isEmpty {
            notes.append("pruning skipped — \(failedCount) fetch failure(s)")
        }

        let onWatch = await WorkoutScheduler.shared.scheduledWorkouts.count
        let failureSummary = failedCount > 0 ? "\(failedCount) workout\(failedCount == 1 ? "" : "s") failed to load" : nil

        return SyncReport(
            date: Date(), trigger: trigger, onWatch: onWatch,
            added: added, removed: removed, kept: kept, skipped: skipped,
            error: failureSummary, failed: failedCount, notes: notes.isEmpty ? nil : notes
        )
    }

    /// Fetch → decode → reconcile a single item against the watch schedule.
    /// Runs inside the task group; mutations for one item stay ordered within its own task
    /// (remove-old before schedule-new), so concurrent items can't corrupt each other.
    private static func processItem(
        _ item: FeedItem,
        manifestURL: URL,
        config: AppConfig,
        existingByKey: [PlanKey: ScheduledWorkoutPlan],
        onEvent: (@Sendable (SyncEvent) -> Void)?
    ) async -> ItemOutcome {
        let key = uiKey(item)
        let label = FeedClient.label(of: item)

        switch FeedClient.kind(of: item) {
        case .unsupported(let type):
            onEvent?(.itemUpdate(uiKey: key, state: .skipped("unsupported type “\(type)”"), title: nil, symbol: nil))
            return ItemOutcome(label: label, kind: .skipped, matched: nil, note: "\(label) — unsupported type “\(type)”")
        case .appleWorkout:
            break
        }

        do {
            let data = try await FeedClient.fetchItemData(item, manifestURL: manifestURL, config: config)
            let plan: WorkoutPlan
            do {
                plan = try WorkoutPlan(from: data)
            } catch {
                onEvent?(.itemUpdate(uiKey: key, state: .failed("not a valid .workout file"), title: nil, symbol: nil))
                return ItemOutcome(label: label, kind: .failed, matched: nil, note: nil)
            }
            let components = dateComponents(fromISO: item.date)
            let planKey = PlanKey(planID: plan.id, date: components)
            let title = item.title ?? plan.displayTitle
            let symbol = plan.activitySymbol

            if let match = existingByKey[planKey] {
                if match.plan == plan {
                    onEvent?(.itemUpdate(uiKey: key, state: .onWatch(complete: match.complete), title: title, symbol: symbol))
                    return ItemOutcome(label: label, kind: .kept, matched: match, note: nil)
                }
                // Same workout id + date but changed content: replace (ordered within this task).
                await WorkoutScheduler.shared.remove(match.plan, at: match.date)
                await WorkoutScheduler.shared.schedule(plan, at: components)
                onEvent?(.itemUpdate(uiKey: key, state: .onWatch(complete: false), title: title, symbol: symbol))
                return ItemOutcome(label: label, kind: .added, matched: match, note: nil)
            }

            await WorkoutScheduler.shared.schedule(plan, at: components)
            onEvent?(.itemUpdate(uiKey: key, state: .onWatch(complete: false), title: title, symbol: symbol))
            return ItemOutcome(label: label, kind: .added, matched: nil, note: nil)
        } catch {
            onEvent?(.itemUpdate(uiKey: key, state: .failed(error.localizedDescription), title: nil, symbol: nil))
            return ItemOutcome(label: label, kind: .failed, matched: nil, note: nil)
        }
    }

    private struct PlanKey: Hashable, Sendable {
        let planID: UUID
        let year: Int?
        let month: Int?
        let day: Int?
        let hour: Int?
        let minute: Int?

        init(planID: UUID, date: DateComponents) {
            self.planID = planID
            year = date.year
            month = date.month
            day = date.day
            hour = date.hour
            minute = date.minute
        }
    }

    // MARK: - Scheduler helpers

    static func scheduledPlans() async -> [ScheduledWorkoutPlan] {
        let plans = await WorkoutScheduler.shared.scheduledWorkouts
        return plans.sorted { (date(of: $0) ?? .distantFuture) < (date(of: $1) ?? .distantFuture) }
    }

    @discardableResult
    static func clearAllScheduled() async -> Int {
        let count = await WorkoutScheduler.shared.scheduledWorkouts.count
        await WorkoutScheduler.shared.removeAllWorkouts()
        return count
    }

    static func date(of scheduled: ScheduledWorkoutPlan) -> Date? {
        Calendar.current.date(from: scheduled.date)
    }

    // MARK: - Background refresh (opportunistic top-up; every run re-applies the whole window)

    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        // iOS treats this as "no earlier than" and won't run BG tasks anywhere near 30s —
        // clamp to 15 min; short debug intervals are served by the foreground polling loop.
        let interval = max(ConfigStore.syncInterval, 15 * 60)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func backgroundRefresh() async {
        scheduleBackgroundRefresh() // chain the next fire regardless of this one's outcome
        guard ConfigStore.load() != nil else { return }
        await sync(trigger: "background")
    }

    // MARK: - Date parsing

    /// Parses `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM(:SS)` as local wall-clock. Time defaults to 07:00.
    static func dateComponents(fromISO iso: String) -> DateComponents {
        var components = DateComponents()
        components.hour = defaultHour
        components.minute = 0

        let dateAndTime = iso.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        let dateParts = (dateAndTime.first.map(String.init) ?? "").split(separator: "-")
        if dateParts.count == 3 {
            components.year = Int(dateParts[0])
            components.month = Int(dateParts[1])
            components.day = Int(dateParts[2])
        }
        if dateAndTime.count >= 2 {
            let timeParts = dateAndTime[1].split(separator: ":")
            if timeParts.count >= 1 { components.hour = Int(timeParts[0]) }
            if timeParts.count >= 2 { components.minute = Int(timeParts[1]) }
        }
        return components
    }
}

// MARK: - Display helpers

extension WorkoutPlan {
    var displayTitle: String {
        if case .custom(let custom) = workout, let name = custom.displayName, !name.isEmpty {
            return name
        }
        return workout.activity.displayName
    }

    var activitySymbol: String {
        workout.activity.symbolName
    }
}

extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running: return "Run"
        case .cycling: return "Ride"
        case .walking: return "Walk"
        case .swimming: return "Swim"
        case .hiking: return "Hike"
        case .functionalStrengthTraining, .traditionalStrengthTraining: return "Strength"
        case .yoga: return "Yoga"
        case .rowing: return "Row"
        default: return "Workout"
        }
    }

    var symbolName: String {
        switch self {
        case .running: return "figure.run"
        case .cycling: return "figure.outdoor.cycle"
        case .walking: return "figure.walk"
        case .swimming: return "figure.pool.swim"
        case .hiking: return "figure.hiking"
        case .functionalStrengthTraining, .traditionalStrengthTraining: return "figure.strengthtraining.traditional"
        case .yoga: return "figure.yoga"
        case .rowing: return "figure.rower"
        default: return "figure.mixed.cardio"
        }
    }
}
