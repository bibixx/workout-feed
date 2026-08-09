import SwiftUI

struct OnboardingView: View {
    let onConnected: () -> Void

    @State private var feedURL = ""
    @State private var authHeader = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showSetupGuide = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "applewatch.radiowaves.left.and.right")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                        Text("Workouts on your wrist")
                            .font(.title2.bold())
                        Text("Point the app at a workout feed and your planned workouts will show up in the Workout app on your Apple Watch — automatically.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Feed URL", text: $feedURL, prompt: Text("https://example.com/workouts/index.json"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Authorization header (optional)", text: $authHeader)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        showSetupGuide = true
                    } label: {
                        Label("How do I set up a feed?", systemImage: "questionmark.circle")
                    }
                } header: {
                    Text("Feed")
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("Get these values from the service that publishes your workouts.")
                    }
                }

                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Text("Connect")
                            if busy {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(busy || feedURL.trimmed.isEmpty)
                }
            }
            .navigationTitle("Workout Feed")
            .sheet(isPresented: $showSetupGuide) {
                SafariView(url: AppLinks.feedSetupDocs)
                    .ignoresSafeArea()
            }
        }
    }

    @MainActor
    private func connect() async {
        busy = true
        defer { busy = false }
        error = nil

        // Validate with a single manifest fetch — fast. The workout files download in the
        // background on the home screen, with per-row progress.
        let config = AppConfig(feedURL: feedURL, authHeader: authHeader.trimmed.isEmpty ? nil : authHeader)
        do {
            _ = try await FeedClient.fetchManifest(config: config)
            ConfigStore.save(config)
            onConnected()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
