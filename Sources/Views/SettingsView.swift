import SwiftUI
import WorkoutKit

struct SettingsView: View {
    @ObservedObject var model: SyncModel
    let onDisconnect: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var feedURL = ""
    @State private var authHeader = ""
    @State private var feedback: String?
    @State private var busy = false
    @State private var confirmDisconnect = false
    @State private var versionTaps = 0
    @State private var showSetupGuide = false
    @AppStorage(ConfigStore.debugUnlockedKey) private var debugUnlocked = false
    @AppStorage(ConfigStore.syncIntervalKey) private var syncInterval = ConfigStore.defaultSyncInterval

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Feed URL", text: $feedURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Authorization header (optional)", text: $authHeader)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(busy ? "Working…" : "Save & sync") {
                        Task { await saveAndSync() }
                    }
                    .disabled(busy || feedURL.trimmed.isEmpty)
                    Button {
                        showSetupGuide = true
                    } label: {
                        Label("How to set up a feed", systemImage: "questionmark.circle")
                    }
                } header: {
                    Text("Feed")
                } footer: {
                    if let feedback {
                        Text(feedback)
                    }
                }

                Section {
                    Picker("Check for new workouts", selection: $syncInterval) {
                        ForEach(intervalOptions, id: \.seconds) { option in
                            Text(option.label).tag(option.seconds)
                        }
                    }
                    Button("Sync now") {
                        Task { await syncNow() }
                    }
                    .disabled(busy)
                    if let report = ReportStore.last {
                        LabeledContent("Last sync", value: report.date.formatted(date: .abbreviated, time: .shortened))
                    }
                } footer: {
                    Text("Checks run on this schedule while the app is open. In the background, iOS decides the actual timing (best effort).")
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                        .contentShape(Rectangle())
                        .onTapGesture { registerVersionTap() }
                    if debugUnlocked {
                        NavigationLink("Debug") { DebugView() }
                    }
                }

                Section {
                    Button("Disconnect", role: .destructive) {
                        confirmDisconnect = true
                    }
                    .disabled(busy)
                } footer: {
                    Text("Removes the feed and clears every workout this app scheduled on your watch.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: load)
            .sheet(isPresented: $showSetupGuide) {
                SafariView(url: AppLinks.feedSetupDocs)
                    .ignoresSafeArea()
            }
            .confirmationDialog("Disconnect this feed?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect & clear watch", role: .destructive) {
                    disconnect()
                }
            }
        }
    }

    private var intervalOptions: [(label: String, seconds: TimeInterval)] {
        var options: [(label: String, seconds: TimeInterval)] = [
            ("Every 15 minutes", 15 * 60),
            ("Every hour", 60 * 60),
            ("Every 6 hours", 6 * 60 * 60),
            ("Once a day", 24 * 60 * 60),
        ]
        if debugUnlocked {
            options.insert(("Every 30 seconds (debug)", 30), at: 0)
        }
        return options
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func load() {
        let config = ConfigStore.load()
        feedURL = config?.feedURL ?? ""
        authHeader = config?.authHeader ?? ""
    }

    private func registerVersionTap() {
        versionTaps += 1
        if versionTaps >= 5, !debugUnlocked {
            debugUnlocked = true
            feedback = "Debug unlocked."
        }
    }

    @MainActor
    private func saveAndSync() async {
        busy = true
        defer { busy = false }
        feedback = nil
        ConfigStore.save(AppConfig(feedURL: feedURL, authHeader: authHeader.trimmed.isEmpty ? nil : authHeader))
        await model.sync(trigger: "settings")
        feedback = statusText(model.lastReport)
    }

    @MainActor
    private func syncNow() async {
        busy = true
        defer { busy = false }
        await model.sync(trigger: "manual")
        feedback = statusText(model.lastReport)
    }

    private func statusText(_ report: SyncReport?) -> String {
        guard let report else { return "Synced." }
        return report.error ?? "Synced — \(report.onWatch) workout\(report.onWatch == 1 ? "" : "s") on the watch."
    }

    @MainActor
    private func disconnect() {
        ConfigStore.clear()
        ReportStore.clear() // history belongs to the old feed; also resets the launch throttle
        dismiss()
        onDisconnect()
        // The watch wipe takes however long the system takes — no reason to make the user
        // watch it. If it's ever interrupted, the next connect's sync prunes leftovers anyway.
        Task.detached(priority: .utility) {
            await WorkoutScheduler.shared.removeAllWorkouts()
        }
    }
}
