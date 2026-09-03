#if os(iOS) && canImport(ActivityKit)
  import ActivityKit
  import Foundation

  @available(iOS 16.2, *)
  @MainActor
  public final class LiveActivityCoordinator {
    public static let shared = LiveActivityCoordinator()

    private init() {}

    public var isRunning: Bool {
      Activity<AgentIslandActivityAttributes>.activities.contains { activity in
        activity.activityState != .ended && activity.activityState != .dismissed
      }
    }

    public func start(using snapshot: AgentIslandSnapshot) async throws {
      guard ActivityAuthorizationInfo().areActivitiesEnabled else {
        throw LiveActivityError.disabled
      }
      guard Self.hasFreshActiveAgent(in: snapshot) else {
        throw LiveActivityError.noActiveAgent
      }

      let state = AgentIslandActivityAttributes.ContentState(snapshot: snapshot)
      let content = ActivityContent(
        state: state,
        staleDate: Date().addingTimeInterval(2 * 60),
        relevanceScore: 80
      )

      if let activity = Activity<AgentIslandActivityAttributes>.activities.first(where: {
        $0.activityState != .ended && $0.activityState != .dismissed
      }) {
        await activity.update(content)
        return
      }

      _ = try Activity.request(
        attributes: AgentIslandActivityAttributes(
          sourceLabel: snapshot.sync.transport == .preview ? "SAMPLE" : "Mac"
        ),
        content: content,
        pushType: nil
      )
    }

    public func update(using snapshot: AgentIslandSnapshot) async {
      let content = ActivityContent(
        state: AgentIslandActivityAttributes.ContentState(snapshot: snapshot),
        staleDate: Date().addingTimeInterval(2 * 60),
        relevanceScore: snapshot.activeAgents.isEmpty ? 0 : 80
      )

      for activity in Activity<AgentIslandActivityAttributes>.activities {
        if !Self.hasFreshActiveAgent(in: snapshot) {
          await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(60)))
        } else {
          await activity.update(content)
        }
      }
    }

    public func stop() async {
      for activity in Activity<AgentIslandActivityAttributes>.activities {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
    }

    private static func hasFreshActiveAgent(in snapshot: AgentIslandSnapshot) -> Bool {
      let age = Date().timeIntervalSince(snapshot.generatedAt)
      return !snapshot.activeAgents.isEmpty && age >= -60 && age <= 3 * 60
    }
  }

  public enum LiveActivityError: LocalizedError {
    case disabled
    case noActiveAgent

    public var errorDescription: String? {
      switch self {
      case .disabled:
        return NSLocalizedString("activity.error.disabled", comment: "")
      case .noActiveAgent:
        return NSLocalizedString("activity.error.no_agent", comment: "")
      }
    }
  }
#endif
