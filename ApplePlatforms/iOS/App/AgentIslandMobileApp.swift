import SwiftUI

@main
struct AgentIslandMobileApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var store = DashboardStore(provider: CloudKitSnapshotProvider())

  var body: some Scene {
    WindowGroup {
      DashboardView(store: store)
        .task { await store.refresh() }
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active else {
        // Never leave an explicitly revealed conversation title in the app
        // switcher snapshot. Returning to the foreground requires another
        // deliberate local reveal action, even if the refresh is offline.
        store.hideFullConversationTitles()
        return
      }
      Task { await store.refresh() }
    }
  }
}
