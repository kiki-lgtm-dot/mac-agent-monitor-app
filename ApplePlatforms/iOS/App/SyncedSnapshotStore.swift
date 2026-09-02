import Foundation

/// Abstraction for a CloudKit or HTTPS adapter. The iPhone app never reads the
/// Mac's filesystem; it only consumes a validated snapshot delivered by a sync
/// transport and cached inside its own sandbox.
public protocol AgentSnapshotProviding: Sendable {
  func fetchSnapshot() async throws -> AgentIslandSnapshot
}

public actor SyncedSnapshotStore {
  public static let maximumPayloadBytes = 2 * 1_024 * 1_024
  private let rootDirectoryURL: URL
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    let root =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    self.rootDirectoryURL = root.appendingPathComponent("AgentIslandMobile", isDirectory: true)
    self.fileManager = fileManager
  }

  public func fetchSnapshot(forAccountKey accountKey: String) async throws -> AgentIslandSnapshot {
    try removeLegacyUnscopedCacheIfPresent()
    let fileURL = try snapshotURL(forAccountKey: accountKey)
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return .empty
    }
    let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
    guard let fileSize = values.fileSize,
      fileSize >= 0,
      fileSize <= Self.maximumPayloadBytes
    else {
      throw SnapshotValidationError.payloadTooLarge
    }
    let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    let snapshot = try SnapshotCodec.decode(data)
    try SnapshotValidator.validate(snapshot)
    return snapshot
  }

  /// Called by the CloudKit receiver (or a future authenticated HTTPS adapter).
  /// The payload is never interpreted as a local Mac path and is written only
  /// to the iPhone app sandbox after decoding and validation.
  @discardableResult
  public func receiveSyncedPayload(
    _ data: Data,
    transport: SyncTransport? = nil,
    forAccountKey accountKey: String
  ) async throws -> AgentIslandSnapshot {
    guard data.count <= Self.maximumPayloadBytes else {
      throw SnapshotValidationError.payloadTooLarge
    }

    var snapshot = try SnapshotCodec.decode(data)
    try SnapshotValidator.validate(snapshot)

    if let transport {
      snapshot.sync.transport = transport
      snapshot.sync.receivedAt = .now
      snapshot.sync.isFromCache = false
    }

    // A delayed CloudKit response must not roll a newer local cache backward.
    if var current = try? await fetchSnapshot(forAccountKey: accountKey),
      current.generatedAt > snapshot.generatedAt
    {
      current.sync.isFromCache = true
      return current
    }

    let normalizedData = try SnapshotCodec.encode(snapshot)

    let fileURL = try snapshotURL(forAccountKey: accountKey)
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    )
    try normalizedData.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    return snapshot
  }

  /// Removes only the cache that belongs to the resolved iCloud account. A
  /// missing record is a deletion/unpaired signal and must not reveal another
  /// account's last snapshot.
  public func clearSnapshot(forAccountKey accountKey: String) async throws {
    let fileURL = try snapshotURL(forAccountKey: accountKey)
    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    try fileManager.removeItem(at: fileURL)
  }

  private func snapshotURL(forAccountKey accountKey: String) throws -> URL {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
    guard accountKey.count == 64,
      accountKey.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else {
      throw SnapshotValidationError.invalidAccountKey
    }

    return
      rootDirectoryURL
      .appendingPathComponent("Accounts", isDirectory: true)
      .appendingPathComponent(accountKey, isDirectory: true)
      .appendingPathComponent("latest-snapshot.json", isDirectory: false)
  }

  /// Builds before account-scoped caching used one shared file. Never migrate
  /// it into an account cache because its owner cannot be proven after upgrade.
  private func removeLegacyUnscopedCacheIfPresent() throws {
    let legacyURL = rootDirectoryURL.appendingPathComponent(
      "latest-snapshot.json",
      isDirectory: false
    )
    guard fileManager.fileExists(atPath: legacyURL.path) else { return }
    try fileManager.removeItem(at: legacyURL)
  }
}

public enum SnapshotValidator {
  private static let maximumAgents = 100
  private static let maximumConversations = 500
  private static let maximumNameLength = 160
  private static let maximumSummaryLength = 280
  private static let maximumFutureClockSkew: TimeInterval = 5 * 60

  public static func validate(_ snapshot: AgentIslandSnapshot) throws {
    guard snapshot.sourceDevice.id == "mac",
      snapshot.sourceDevice.name == "Mac",
      snapshot.sourceDevice.platform == "macOS"
    else {
      throw SnapshotValidationError.invalidSourceDevice
    }

    guard snapshot.agents.count <= maximumAgents else {
      throw SnapshotValidationError.tooManyAgents
    }

    let conversationCount = snapshot.agents.reduce(0) { $0 + $1.conversations.count }
    guard conversationCount <= maximumConversations else {
      throw SnapshotValidationError.tooManyConversations
    }

    let latestAllowedDate = Date().addingTimeInterval(maximumFutureClockSkew)
    guard snapshot.generatedAt <= latestAllowedDate,
      snapshot.sync.receivedAt <= latestAllowedDate
    else {
      throw SnapshotValidationError.invalidTimestamp
    }

    try validateUsage(snapshot.usage)

    var agentIdentifiers = Set<String>()
    var conversationIdentifiers = Set<String>()
    for agent in snapshot.agents {
      try validateText(agent.id, maximumLength: maximumNameLength, allowsEmpty: false)
      try validateText(agent.displayName, maximumLength: maximumNameLength, allowsEmpty: false)
      try validateText(agent.toolName, maximumLength: maximumNameLength, allowsEmpty: false)
      guard agent.updatedAt <= latestAllowedDate else {
        throw SnapshotValidationError.invalidTimestamp
      }
      guard agentIdentifiers.insert(agent.id).inserted else {
        throw SnapshotValidationError.duplicateIdentifier
      }
      try validateUsage(agent.usage)

      for conversation in agent.conversations {
        try validateText(
          conversation.id,
          maximumLength: maximumNameLength,
          allowsEmpty: false
        )
        try validateText(
          conversation.safeSummary,
          maximumLength: maximumSummaryLength,
          allowsEmpty: true
        )
        if let title = conversation.title {
          guard snapshot.sync.includesFullConversationTitles else {
            throw SnapshotValidationError.undisclosedConversationTitle
          }
          try validateText(title, maximumLength: maximumSummaryLength, allowsEmpty: false)
        }
        guard conversationIdentifiers.insert(conversation.id).inserted else {
          throw SnapshotValidationError.duplicateIdentifier
        }
        try validateUsage(conversation.usage)
      }
    }
  }

  private static func validateUsage(_ usage: TokenUsage) throws {
    guard usage.cachedInput <= usage.input else {
      throw SnapshotValidationError.invalidTokenUsage
    }
  }

  private static func validateText(
    _ value: String,
    maximumLength: Int,
    allowsEmpty: Bool
  ) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count <= maximumLength,
      allowsEmpty || !trimmed.isEmpty,
      value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else {
      throw SnapshotValidationError.invalidText
    }
  }
}

public enum SnapshotValidationError: LocalizedError, Equatable {
  case payloadTooLarge
  case tooManyAgents
  case tooManyConversations
  case invalidTimestamp
  case invalidText
  case invalidTokenUsage
  case invalidAccountKey
  case invalidSourceDevice
  case duplicateIdentifier
  case undisclosedConversationTitle

  public var errorDescription: String? {
    switch self {
    case .payloadTooLarge: return "The synced payload is too large."
    case .tooManyAgents: return "The synced payload contains too many agents."
    case .tooManyConversations: return "The synced payload contains too many conversations."
    case .invalidTimestamp: return "The synced payload has an invalid timestamp."
    case .invalidText: return "The synced payload contains invalid text."
    case .invalidTokenUsage: return "The synced payload contains invalid token usage."
    case .invalidAccountKey: return "The iCloud account cache key is invalid."
    case .invalidSourceDevice: return "The synced payload has an invalid source device."
    case .duplicateIdentifier: return "The synced payload contains duplicate identifiers."
    case .undisclosedConversationTitle:
      return "The synced payload contains a conversation title without title-sync consent."
    }
  }
}

#if DEBUG
  public struct PreviewSnapshotProvider: AgentSnapshotProviding {
    public init() {}
    public func fetchSnapshot() async throws -> AgentIslandSnapshot { .preview }
  }
#endif
