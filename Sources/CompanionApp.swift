import SwiftUI

@main
struct CompanionApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .backgroundTask(.appRefresh(SyncEngine.refreshTaskID)) {
            await SyncEngine.backgroundRefresh()
        }
    }
}
