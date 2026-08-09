import SwiftUI

struct RootView: View {
    @State private var configured = ConfigStore.load() != nil
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if configured {
                HomeView(onDisconnect: { configured = false })
            } else {
                OnboardingView(onConnected: { configured = true })
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                SyncEngine.scheduleBackgroundRefresh()
            }
        }
    }
}
