import Foundation
import SwiftUI

@MainActor
public final class DashboardStore: ObservableObject {
  static let exampleModePreferenceKey = "mobile.example-mode-enabled"

  @Published public private(set) var snapshot: AgentIslandSnapshot = .empty
  @Published public private(set) var isRefreshing = false
  @Published public private(set) var errorMessage: String?
  @Published public private(set) var revealFullConversationTitles = false
  @Published public private(set) var isLiveActivityRunning = false
  @Published public private(set) var isExampleModeEnabled: Bool

  private let productionProvider: any AgentSnapshotProviding
  private let exampleProvider: any AgentSnapshotProviding
  private let userDefaults: UserDefaults
  private var refreshGeneration: UInt64 = 0

  public init(
    provider: any AgentSnapshotProviding,
    exampleProvider: any AgentSnapshotProviding = PreviewSnapshotProvider(),
    userDefaults: UserDefaults = .standard
  ) {
    self.productionProvider = provider
    self.exampleProvider = exampleProvider
    self.userDefaults = userDefaults
    self.isExampleModeEnabled = userDefaults.bool(forKey: Self.exampleModePreferenceKey)

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
    refreshGeneration = refreshGeneration &+ 1
    let generation = refreshGeneration
    let exampleModeAtStart = isExampleModeEnabled
    let selectedProvider = exampleModeAtStart ? exampleProvider : productionProvider
    isRefreshing = true
    defer {
      if generation == refreshGeneration {
        isRefreshing = false
      }
    }

    do {
      let latest = try await selectedProvider.fetchSnapshot()
      guard generation == refreshGeneration,
        exampleModeAtStart == isExampleModeEnabled
      else {
        return
      }

      // Example data must stay distinguishable from a real CloudKit result.
      // Refuse a misconfigured example provider instead of relabelling it here.
      if exampleModeAtStart, latest.sync.transport != .preview {
        errorMessage = NSLocalizedString("example.error.invalid_data", comment: "")
        snapshot = .empty
        return
      }

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
      guard generation == refreshGeneration,
        exampleModeAtStart == isExampleModeEnabled
      else {
        return
      }

      if exampleModeAtStart {
        snapshot = .empty
        revealFullConversationTitles = false
        errorMessage = NSLocalizedString("example.error", comment: "")
        return
      }

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

  /// Enables the bundled example without touching CloudKit or the synced cache.
  /// The boolean preference is the only example-mode value persisted locally.
  public func enterExampleMode() async {
    guard !isExampleModeEnabled else { return }
    invalidateCurrentRefresh()
    userDefaults.set(true, forKey: Self.exampleModePreferenceKey)
    isExampleModeEnabled = true
    await resetVisibleStateForModeChange()
    await refresh()
  }

  /// Removes the example preference and immediately resumes the unchanged
  /// production provider. Any example Live Activity is ended first so sample
  /// metrics cannot remain on the Lock Screen after leaving the mode.
  public func exitAndResetExampleMode() async {
    guard isExampleModeEnabled else { return }
    invalidateCurrentRefresh()
    userDefaults.removeObject(forKey: Self.exampleModePreferenceKey)
    isExampleModeEnabled = false
    await resetVisibleStateForModeChange()
    await refresh()
  }

  private func invalidateCurrentRefresh() {
    refreshGeneration = refreshGeneration &+ 1
    isRefreshing = false
  }

  private func resetVisibleStateForModeChange() async {
    snapshot = .empty
    revealFullConversationTitles = false
    errorMessage = nil

    #if os(iOS) && canImport(ActivityKit)
      if #available(iOS 16.2, *) {
        await LiveActivityCoordinator.shared.stop()
        isLiveActivityRunning = false
      }
    #endif
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

  /// Hides sensitive titles as soon as the scene leaves the foreground so an
  /// app-switcher snapshot cannot retain the user's explicit reveal state.
  public func hideFullConversationTitles() {
    revealFullConversationTitles = false
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
