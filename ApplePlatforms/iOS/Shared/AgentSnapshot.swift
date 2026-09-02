import Foundation

/// A privacy-minimized snapshot sent to the iPhone companion.
///
/// This schema intentionally has no prompt, response, workspace path, API key,
/// process identifier, or local-file URL fields. A Mac producer should call
/// `redactedForSync()` before uploading a snapshot.
public struct AgentIslandSnapshot: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var generatedAt: Date
  public var sourceDevice: SourceDevice
  public var usage: TokenUsage
  public var agents: [AgentSummary]
  public var sync: SyncMetadata

  public init(
    schemaVersion: Int = AgentIslandSnapshot.currentSchemaVersion,
    generatedAt: Date,
    sourceDevice: SourceDevice,
    usage: TokenUsage,
    agents: [AgentSummary],
    sync: SyncMetadata
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.sourceDevice = sourceDevice
    self.usage = usage
    self.agents = agents
    self.sync = sync
  }

  public var activeAgents: [AgentSummary] {
    agents.filter(\.isWorking)
  }

  /// The Mac producer already removes unrelated applications before upload.
  /// Preserve every tool it deliberately included, even when the tool has no
  /// current conversation or measured token usage.
  public var relevantAgents: [AgentSummary] {
    agents
  }

  public var activeConversationCount: Int {
    agents.reduce(into: 0) { count, agent in
      count += agent.conversations.filter(\.isWorking).count
    }
  }

  public var longestActiveDurationSeconds: UInt64 {
    activeAgents.map(\.activeDurationSeconds).max() ?? 0
  }

  /// Removes full conversation titles unless the user explicitly opted in on
  /// the source Mac. Safe summaries remain available for useful mobile status.
  public func redactedForSync(includeFullConversationTitles: Bool = false) -> Self {
    var copy = self
    copy.agents = agents.map { agent in
      var redactedAgent = agent
      redactedAgent.conversations = agent.conversations.map { conversation in
        var redactedConversation = conversation
        if !includeFullConversationTitles {
          redactedConversation.title = nil
        }
        return redactedConversation
      }
      return redactedAgent
    }
    copy.sync.includesFullConversationTitles = includeFullConversationTitles
    return copy
  }

  public static let empty = AgentIslandSnapshot(
    generatedAt: .distantPast,
    sourceDevice: SourceDevice(id: "unpaired", name: "Mac", platform: "macOS"),
    usage: .zero,
    agents: [],
    sync: SyncMetadata(
      transport: .notConfigured,
      receivedAt: .distantPast,
      includesFullConversationTitles: false
    )
  )
}

public struct SourceDevice: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var platform: String

  public init(id: String, name: String, platform: String) {
    self.id = id
    self.name = name
    self.platform = platform
  }
}

public struct AgentSummary: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var displayName: String
  public var toolName: String
  public var state: AgentState
  public var activeDurationSeconds: UInt64
  public var usage: TokenUsage
  public var conversations: [ConversationSummary]
  public var updatedAt: Date

  public init(
    id: String,
    displayName: String,
    toolName: String,
    state: AgentState,
    activeDurationSeconds: UInt64,
    usage: TokenUsage,
    conversations: [ConversationSummary],
    updatedAt: Date
  ) {
    self.id = id
    self.displayName = displayName
    self.toolName = toolName
    self.state = state
    self.activeDurationSeconds = activeDurationSeconds
    self.usage = usage
    self.conversations = conversations
    self.updatedAt = updatedAt
  }

  public var isWorking: Bool { state == .working }
}

public struct ConversationSummary: Codable, Equatable, Identifiable, Sendable {
  public var id: String

  /// Optional sensitive title. The mobile UI hides it by default and the Mac
  /// should omit it from the sync payload unless the user opts in.
  public var title: String?

  /// A short, non-sensitive description prepared by the source Mac, for
  /// example "Updating tests". It must not contain prompt or response text.
  public var safeSummary: String
  public var state: AgentState
  public var activeDurationSeconds: UInt64
  public var usage: TokenUsage

  public init(
    id: String,
    title: String? = nil,
    safeSummary: String,
    state: AgentState,
    activeDurationSeconds: UInt64,
    usage: TokenUsage
  ) {
    self.id = id
    self.title = title
    self.safeSummary = safeSummary
    self.state = state
    self.activeDurationSeconds = activeDurationSeconds
    self.usage = usage
  }

  public var isWorking: Bool { state == .working }
}

public enum AgentState: String, Codable, CaseIterable, Equatable, Sendable {
  case working
  case idle
  case completed
  case failed

  public var localizationKey: String {
    "state.\(rawValue)"
  }
}

/// `cachedInput` is a subset of `input`; consumers must not add it to `total`.
public struct TokenUsage: Codable, Equatable, Sendable {
  public var total: UInt64
  public var input: UInt64
  public var cachedInput: UInt64
  public var output: UInt64
  public var reasoning: UInt64
  public var unclassified: UInt64

  public init(
    total: UInt64,
    input: UInt64 = 0,
    cachedInput: UInt64 = 0,
    output: UInt64 = 0,
    reasoning: UInt64 = 0,
    unclassified: UInt64 = 0
  ) {
    self.total = total
    self.input = input
    self.cachedInput = min(cachedInput, input)
    self.output = output
    self.reasoning = reasoning
    self.unclassified = unclassified
  }

  public static let zero = TokenUsage(total: 0)
}

public struct SyncMetadata: Codable, Equatable, Sendable {
  public var transport: SyncTransport
  public var receivedAt: Date
  public var includesFullConversationTitles: Bool
  /// `true` is set only in memory when a remote refresh fails and the last
  /// validated iPhone cache is displayed instead.
  public var isFromCache: Bool?

  public init(
    transport: SyncTransport,
    receivedAt: Date,
    includesFullConversationTitles: Bool,
    isFromCache: Bool? = nil
  ) {
    self.transport = transport
    self.receivedAt = receivedAt
    self.includesFullConversationTitles = includesFullConversationTitles
    self.isFromCache = isFromCache
  }
}

public enum SyncTransport: String, Codable, Equatable, Sendable {
  case notConfigured
  case cloudKit
  case customHTTPS
  case nearbyDevice
  case preview
}

public enum SnapshotCodec {
  public static func decode(_ data: Data) throws -> AgentIslandSnapshot {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()

      // Accept epoch milliseconds from the existing Mac snapshot as well as
      // epoch seconds from conventional JSON APIs.
      if let numericTimestamp = try? container.decode(Double.self) {
        let seconds =
          numericTimestamp > 100_000_000_000
          ? numericTimestamp / 1_000
          : numericTimestamp
        return Date(timeIntervalSince1970: seconds)
      }

      let timestamp = try container.decode(String.self)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: timestamp) {
        return date
      }
      formatter.formatOptions = [.withInternetDateTime]
      if let date = formatter.date(from: timestamp) {
        return date
      }

      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected an ISO-8601 or epoch timestamp."
      )
    }
    let snapshot = try decoder.decode(AgentIslandSnapshot.self, from: data)
    guard snapshot.schemaVersion == AgentIslandSnapshot.currentSchemaVersion else {
      throw SnapshotCodecError.unsupportedSchema(snapshot.schemaVersion)
    }
    return snapshot
  }

  public static func encode(_ snapshot: AgentIslandSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      try container.encode(formatter.string(from: date))
    }
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(snapshot)
  }
}

public enum SnapshotCodecError: LocalizedError, Equatable {
  case unsupportedSchema(Int)

  public var errorDescription: String? {
    switch self {
    case .unsupportedSchema(let version):
      return "Unsupported Aivulet snapshot schema: \(version)"
    }
  }
}

#if DEBUG
  extension AgentIslandSnapshot {
    public static let preview = AgentIslandSnapshot(
      generatedAt: .now,
      sourceDevice: SourceDevice(id: "preview-mac", name: "Studio Mac", platform: "macOS"),
      usage: TokenUsage(
        total: 1_284_920,
        input: 1_107_200,
        cachedInput: 620_400,
        output: 151_720,
        reasoning: 26_000
      ),
      agents: [
        AgentSummary(
          id: "codex-root",
          displayName: "Codex",
          toolName: "Codex",
          state: .working,
          activeDurationSeconds: 2_884,
          usage: TokenUsage(
            total: 982_430, input: 830_000, cachedInput: 440_000, output: 134_430, reasoning: 18_000
          ),
          conversations: [
            ConversationSummary(
              id: "conversation-1",
              title: "Prepare the iOS companion release",
              safeSummary: "Preparing mobile release",
              state: .working,
              activeDurationSeconds: 1_924,
              usage: TokenUsage(total: 631_240)
            ),
            ConversationSummary(
              id: "conversation-2",
              title: "Review token aggregation",
              safeSummary: "Reviewing usage totals",
              state: .working,
              activeDurationSeconds: 960,
              usage: TokenUsage(total: 351_190)
            ),
          ],
          updatedAt: .now
        ),
        AgentSummary(
          id: "claude-reviewer",
          displayName: "Claude Code",
          toolName: "Claude Code",
          state: .idle,
          activeDurationSeconds: 713,
          usage: TokenUsage(total: 302_490),
          conversations: [
            ConversationSummary(
              id: "conversation-3",
              safeSummary: "Review complete",
              state: .completed,
              activeDurationSeconds: 713,
              usage: TokenUsage(total: 302_490)
            )
          ],
          updatedAt: .now.addingTimeInterval(-600)
        ),
      ],
      sync: SyncMetadata(
        transport: .preview, receivedAt: .now, includesFullConversationTitles: true)
    )
  }
#endif
