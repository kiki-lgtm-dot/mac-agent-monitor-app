#if os(iOS) && canImport(ActivityKit)
  import ActivityKit
  import Foundation

  /// Shared between the iPhone app and Widget Extension targets.
  public struct AgentIslandActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
      public var runningAgentCount: Int
      public var activeConversationCount: Int
      public var activeDurationSeconds: UInt64
      public var totalTokens: UInt64
      public var status: LiveAgentStatus
      public var lastUpdatedAt: Date

      public init(
        runningAgentCount: Int,
        activeConversationCount: Int,
        activeDurationSeconds: UInt64,
        totalTokens: UInt64,
        status: LiveAgentStatus,
        lastUpdatedAt: Date
      ) {
        self.runningAgentCount = runningAgentCount
        self.activeConversationCount = activeConversationCount
        self.activeDurationSeconds = activeDurationSeconds
        self.totalTokens = totalTokens
        self.status = status
        self.lastUpdatedAt = lastUpdatedAt
      }

      public init(snapshot: AgentIslandSnapshot) {
        let activeTokenTotal = snapshot.activeAgents.reduce(UInt64.zero) { partial, agent in
          let (sum, overflow) = partial.addingReportingOverflow(agent.usage.total)
          return overflow ? UInt64.max : sum
        }
        self.init(
          runningAgentCount: snapshot.activeAgents.count,
          activeConversationCount: snapshot.activeConversationCount,
          activeDurationSeconds: snapshot.longestActiveDurationSeconds,
          totalTokens: activeTokenTotal,
          status: snapshot.activeAgents.isEmpty ? .idle : .working,
          lastUpdatedAt: snapshot.generatedAt
        )
      }
    }

    /// This label should be generic (for example "Mac") rather than a personal
    /// computer name because it can appear on the Lock Screen.
    public var sourceLabel: String
    public var sessionID: UUID

    public init(sourceLabel: String = "Mac", sessionID: UUID = UUID()) {
      self.sourceLabel = sourceLabel
      self.sessionID = sessionID
    }
  }

  public enum LiveAgentStatus: String, Codable, Hashable {
    case working
    case idle
  }
#endif
