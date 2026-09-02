import CloudKit
import CryptoKit
import Foundation

/// Configuration is supplied through App-Info.plist, whose values are expanded
/// from Config/Project.xcconfig. This keeps record identifiers out of view code.
public struct CloudKitSnapshotConfiguration: Sendable {
  public var containerIdentifier: String?
  public var recordType: String
  public var recordName: String
  public var payloadField: String

  public init(
    containerIdentifier: String?,
    recordType: String,
    recordName: String,
    payloadField: String
  ) {
    self.containerIdentifier = containerIdentifier
    self.recordType = recordType
    self.recordName = recordName
    self.payloadField = payloadField
  }

  public static func fromBundle(_ bundle: Bundle = .main) -> Self {
    let container = configuredString(
      in: bundle,
      key: "AgentIslandCloudKitContainerIdentifier",
      fallback: ""
    )
    return CloudKitSnapshotConfiguration(
      containerIdentifier: container.isEmpty ? nil : container,
      recordType: configuredString(
        in: bundle,
        key: "AgentIslandCloudKitRecordType",
        fallback: "AgentIslandSnapshot"
      ),
      recordName: configuredString(
        in: bundle,
        key: "AgentIslandCloudKitRecordName",
        fallback: "latest"
      ),
      payloadField: configuredString(
        in: bundle,
        key: "AgentIslandCloudKitPayloadField",
        fallback: "payloadJSON"
      )
    )
  }

  private static func configuredString(
    in bundle: Bundle,
    key: String,
    fallback: String
  ) -> String {
    guard let value = bundle.object(forInfoDictionaryKey: key) as? String else {
      return fallback
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("$(") else { return fallback }
    return trimmed
  }
}

/// Reads one fixed record from the signed-in user's private CloudKit database.
/// Only the host app compiles this source. The Widget Extension never imports
/// CloudKit and receives only the reduced ActivityKit ContentState.
public actor CloudKitSnapshotProvider: AgentSnapshotProviding {
  private let configuration: CloudKitSnapshotConfiguration
  private let container: CKContainer
  private let privateDatabase: CKDatabase
  private let cache: SyncedSnapshotStore

  public init(
    configuration: CloudKitSnapshotConfiguration = .fromBundle(),
    cache: SyncedSnapshotStore = SyncedSnapshotStore()
  ) {
    self.configuration = configuration
    self.cache = cache
    let resolvedContainer: CKContainer
    if let containerIdentifier = configuration.containerIdentifier {
      resolvedContainer = CKContainer(identifier: containerIdentifier)
    } else {
      resolvedContainer = CKContainer.default()
    }
    self.container = resolvedContainer
    self.privateDatabase = resolvedContainer.privateCloudDatabase
  }

  public func fetchSnapshot() async throws -> AgentIslandSnapshot {
    // Resolve the signed-in account before touching disk. Cache files are keyed
    // by an irreversible digest of the CloudKit user record identifier, so an
    // iCloud account switch can never fall back to another user's snapshot.
    let accountKey = try await resolvedAccountKey()
    let cached = try? await cache.fetchSnapshot(forAccountKey: accountKey)

    do {
      let recordID = CKRecord.ID(recordName: configuration.recordName)
      let record = try await privateDatabase.record(for: recordID)

      // Account changes can race an in-flight CloudKit request. Re-resolve the
      // identity before accepting or caching its result.
      guard try await resolvedAccountKey() == accountKey else {
        throw CloudKitSnapshotError.accountChanged
      }
      guard record.recordType == configuration.recordType else {
        throw CloudKitSnapshotError.unexpectedRecordType(
          expected: configuration.recordType,
          actual: record.recordType
        )
      }

      let payload = try payloadData(from: record)
      let acceptedSnapshot = try await cache.receiveSyncedPayload(
        payload,
        transport: .cloudKit,
        forAccountKey: accountKey
      )
      // The account can still change while the validated payload is being
      // written. Re-check after the await before exposing it in memory. The
      // old account's cache remains isolated under its irreversible key.
      guard try await resolvedAccountKey() == accountKey else {
        throw CloudKitSnapshotError.accountChanged
      }
      return acceptedSnapshot
    } catch {
      if let snapshotError = error as? CloudKitSnapshotError,
        case .accountChanged = snapshotError
      {
        throw error
      }

      // Never use a cache until the account has been verified again. This also
      // prevents a signed-out or temporarily indeterminate account from seeing
      // the previously signed-in user's data.
      guard try await resolvedAccountKey() == accountKey else {
        throw CloudKitSnapshotError.accountChanged
      }

      // A missing fixed record is authoritative: the Mac producer has not
      // uploaded yet, or the user deleted/disabled sync. Remove this account's
      // local copy instead of displaying stale data forever.
      if let cloudError = error as? CKError, cloudError.code == .unknownItem {
        try await cache.clearSnapshot(forAccountKey: accountKey)
        return .empty
      }

      if var cached, cached.generatedAt != .distantPast {
        cached.sync.isFromCache = true
        return cached
      }
      throw error
    }
  }

  private func resolvedAccountKey() async throws -> String {
    let status = try await container.accountStatus()
    guard status == .available else {
      throw CloudKitSnapshotError.accountUnavailable
    }

    let userRecordID: CKRecord.ID
    do {
      userRecordID = try await container.userRecordID()
    } catch let cloudError as CKError where cloudError.code == .notAuthenticated {
      throw CloudKitSnapshotError.accountUnavailable
    }
    let identity = [
      userRecordID.recordName,
      userRecordID.zoneID.zoneName,
      userRecordID.zoneID.ownerName,
    ].joined(separator: "\u{0}")
    let digest = SHA256.hash(data: Data(identity.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func payloadData(from record: CKRecord) throws -> Data {
    guard let value = record[configuration.payloadField] else {
      throw CloudKitSnapshotError.missingPayloadField(configuration.payloadField)
    }

    if let data = value as? Data {
      return data
    }
    if let string = value as? String,
      let data = string.data(using: .utf8)
    {
      return data
    }
    if let asset = value as? CKAsset, let fileURL = asset.fileURL {
      let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
      guard let fileSize = values.fileSize,
        fileSize >= 0,
        fileSize <= SyncedSnapshotStore.maximumPayloadBytes
      else {
        throw SnapshotValidationError.payloadTooLarge
      }
      return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    }

    throw CloudKitSnapshotError.unsupportedPayloadType(configuration.payloadField)
  }
}

public enum CloudKitSnapshotError: LocalizedError, Sendable {
  case missingPayloadField(String)
  case unsupportedPayloadType(String)
  case unexpectedRecordType(expected: String, actual: String)
  case accountUnavailable
  case accountChanged

  public var errorDescription: String? {
    switch self {
    case .missingPayloadField(let field):
      return "CloudKit record is missing the \(field) payload field."
    case .unsupportedPayloadType(let field):
      return "CloudKit field \(field) must be Bytes, String, or Asset."
    case .unexpectedRecordType(let expected, let actual):
      return "Expected CloudKit record type \(expected), received \(actual)."
    case .accountUnavailable:
      return "Sign in to iCloud to load the synced Aivulet snapshot."
    case .accountChanged:
      return "The iCloud account changed while the snapshot was loading. Refresh and try again."
    }
  }
}
