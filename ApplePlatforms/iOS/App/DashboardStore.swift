import Foundation
import SwiftUI

@MainActor
public final class DashboardStore: ObservableObject {
  @Published public private(set) var snapshot: AgentIslandSnapshot = .empty
  @Published public private(set) var isRefreshing = false
  @Published public private(set) var errorMessage: String?
  @Published public var revealFullConversationTitles = false
  @Published public private(set) var isLiveActivityRunning = false

  private let provider: any AgentSnapshotProviding

  public init(provider: any AgentSnapshotProviding) {
    self.provider = provider

    #if os(iOS) && canImport(ActivityKit)
      if #available(iOS 16.2, *) {
        isLiveActivityRunning = LiveActivityCoordinator.shared.isRunning
      }
    #endif
  }

  public var fullTitlesAvailable: Bool {
    snapshot.sync.includesFullConversationTitles
  }

  public func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      let latest = try await provider.fetchSnapshot()
      snapshot = latest
      // A refresh can complete after an iCloud account switch. The payload
      // deliberately contains no account identifier, so require a fresh local
      // reveal action after every accepted snapshot instead of carrying title
      // visibility across accounts.
      revealFullConversationTitles = false
      errorMessage = nil

      #if os(iOS) && canImport(ActivityKit)
        if #available(iOS 16.2, *), isLiveActivityRunning {
          await LiveActivityCoordinator.shared.update(using: latest)
          isLiveActivityRunning = LiveActivityCoordinator.shared.isRunning
        }
      #endif
    } catch {
      if let cloudError = error as? CloudKitSnapshotError {
        switch cloudError {
        case .accountUnavailable:
          await clearAccountScopedState()
          errorMessage = NSLocalizedString("sync.error.account_unavailable", comment: "")
        case .accountChanged:
          await clearAccountScopedState()
          errorMessage = NSLocalizedString("sync.error.account_changed", comment: "")
        default:
          errorMessage = NSLocalizedString("sync.error", comment: "")
        }
      } else {
        errorMessage = NSLocalizedString("sync.error", comment: "")
      }
    }
  }

  /// Removes every account-scoped value before reporting an authentication or
  /// account-change error. In particular, a previous user's in-memory snapshot
  /// and Live Activity must never remain visible after the provider refuses the
  /// current CloudKit identity.
  private func clearAccountScopedState() async {
    snapshot = .empty
    revealFullConversationTitles = false

    #if os(iOS) && canImport(ActivityKit)
      if #available(iOS 16.2, *) {
        await LiveActivityCoordinator.shared.stop()
        isLiveActivityRunning = false
      }
    #endif
  }

  public func toggleTitlePrivacy() {
    guard fullTitlesAvailable else { return }
    revealFullConversationTitles.toggle()
  }

  #if os(iOS) && canImport(ActivityKit)
    public func toggleLiveActivity() async {
      guard #available(iOS 16.2, *) else { return }

      if LiveActivityCoordinator.shared.isRunning {
        await LiveActivityCoordinator.shared.stop()
        isLiveActivityRunning = false
        return
      }

      do {
        try await LiveActivityCoordinator.shared.start(using: snapshot)
        isLiveActivityRunning = LiveActivityCoordinator.shared.isRunning
        errorMessage = nil
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  #endif
}
