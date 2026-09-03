import Foundation
@testable import AgentIslandMobile

enum SnapshotFixtures {
  static let generatedAt = Date(timeIntervalSince1970: 1_780_000_000)

  static func titledSnapshot(
    generatedAt: Date = SnapshotFixtures.generatedAt
  ) -> AgentIslandSnapshot {
    AgentIslandSnapshot(
      generatedAt: generatedAt,
      sourceDevice: SourceDevice(
        id: "mac",
        name: "Mac",
        platform: "macOS"
      ),
      usage: TokenUsage(
        total: 420,
        input: 300,
        cachedInput: 120,
        output: 90,
        reasoning: 30
      ),
      agents: [
        AgentSummary(
          id: "codex-test",
          displayName: "Codex",
          toolName: "Codex",
          state: .working,
          activeDurationSeconds: 75,
          usage: TokenUsage(total: 420),
          conversations: [
            ConversationSummary(
              id: "conversation-test",
              title: "Private release conversation title",
              safeSummary: "Preparing a release",
              state: .working,
              activeDurationSeconds: 75,
              usage: TokenUsage(total: 420)
            )
          ],
          updatedAt: generatedAt
        )
      ],
      sync: SyncMetadata(
        transport: .cloudKit,
        receivedAt: generatedAt.addingTimeInterval(1),
        includesFullConversationTitles: true
      )
    )
  }
}

actor MockSnapshotProvider: AgentSnapshotProviding {
  enum Response: Sendable {
    case snapshot(AgentIslandSnapshot)
    case accountUnavailable
    case accountChanged
  }

  enum Failure: Error {
    case exhausted
  }

  private var responses: [Response]

  init(_ responses: [Response]) {
    self.responses = responses
  }

  func fetchSnapshot() async throws -> AgentIslandSnapshot {
    guard !responses.isEmpty else { throw Failure.exhausted }

    switch responses.removeFirst() {
    case .snapshot(let snapshot):
      return snapshot
    case .accountUnavailable:
      throw CloudKitSnapshotError.accountUnavailable
    case .accountChanged:
      throw CloudKitSnapshotError.accountChanged
    }
  }

  func remainingResponseCount() -> Int {
    responses.count
  }
}
