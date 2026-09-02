#if os(iOS) && canImport(ActivityKit)
  import SwiftUI
  import WidgetKit

  @available(iOSApplicationExtension 16.2, *)
  @main
  struct AgentIslandWidgetBundle: WidgetBundle {
    var body: some Widget {
      AgentIslandLiveActivity()
    }
  }
#endif
