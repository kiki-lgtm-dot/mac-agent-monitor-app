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
      guard newPhase == .active else { return }
      Task { await store.refresh() }
    }
  }
}
