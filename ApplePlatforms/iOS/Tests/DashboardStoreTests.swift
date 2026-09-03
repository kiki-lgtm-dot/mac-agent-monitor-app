import XCTest
@testable import AgentIslandMobile

final class DashboardStoreTests: XCTestCase {
  @MainActor
  func testExampleModeUsesBundledDataThenResumesTheUntouchedProductionProvider() async {
    let (userDefaults, suiteName) = makeIsolatedUserDefaults()
    defer { userDefaults.removePersistentDomain(forName: suiteName) }

    let productionSnapshot = SnapshotFixtures.titledSnapshot()
    let productionProvider = MockSnapshotProvider([.snapshot(productionSnapshot)])
    let store = DashboardStore(
      provider: productionProvider,
      userDefaults: userDefaults
    )

    XCTAssertFalse(store.isExampleModeEnabled)
    XCTAssertNil(userDefaults.object(forKey: DashboardStore.exampleModePreferenceKey))

    await store.enterExampleMode()

    XCTAssertTrue(store.isExampleModeEnabled)
    XCTAssertEqual(store.snapshot.sync.transport, .preview)
    XCTAssertFalse(store.snapshot.sync.includesFullConversationTitles)
    XCTAssertTrue(
      store.snapshot.agents.flatMap(\.conversations).allSatisfy { $0.title == nil }
    )
    XCTAssertEqual(
      userDefaults.object(forKey: DashboardStore.exampleModePreferenceKey) as? Bool,
      true
    )
    let responsesAfterEnteringExample = await productionProvider.remainingResponseCount()
    XCTAssertEqual(
      responsesAfterEnteringExample,
      1,
      "Example mode must not consume or replace the production CloudKit provider."
    )

    await store.exitAndResetExampleMode()

    XCTAssertFalse(store.isExampleModeEnabled)
    XCTAssertEqual(store.snapshot, productionSnapshot)
    XCTAssertNil(userDefaults.object(forKey: DashboardStore.exampleModePreferenceKey))
    let responsesAfterReset = await productionProvider.remainingResponseCount()
    XCTAssertEqual(responsesAfterReset, 0)
  }

  @MainActor
  func testExampleModePreferenceSurvivesRelaunchAndRejectsUnlabelledData() async {
    let (userDefaults, suiteName) = makeIsolatedUserDefaults()
    defer { userDefaults.removePersistentDomain(forName: suiteName) }

    userDefaults.set(true, forKey: DashboardStore.exampleModePreferenceKey)
    let unlabelledProvider = MockSnapshotProvider([
      .snapshot(SnapshotFixtures.titledSnapshot())
    ])
    let store = DashboardStore(
      provider: MockSnapshotProvider([]),
      exampleProvider: unlabelledProvider,
      userDefaults: userDefaults
    )

    XCTAssertTrue(store.isExampleModeEnabled)
    await store.refresh()

    XCTAssertEqual(store.snapshot, .empty)
    XCTAssertNotNil(store.errorMessage)
  }

  @MainActor
  func testSuccessfulRefreshKeepsFullTitlesHiddenByDefault() async {
    let snapshot = SnapshotFixtures.titledSnapshot()
    let provider = MockSnapshotProvider([
      .snapshot(snapshot),
      .snapshot(snapshot),
    ])
    let store = DashboardStore(provider: provider)

    await store.refresh()

    XCTAssertEqual(store.snapshot, snapshot)
    XCTAssertTrue(store.fullTitlesAvailable)
    XCTAssertFalse(store.revealFullConversationTitles)
    XCTAssertNil(store.errorMessage)

    store.toggleTitlePrivacy()
    XCTAssertTrue(store.revealFullConversationTitles)

    await store.refresh()

    XCTAssertEqual(store.snapshot, snapshot)
    XCTAssertFalse(
      store.revealFullConversationTitles,
      "Every accepted refresh must require a new, local reveal action."
    )
    XCTAssertNil(store.errorMessage)
  }

  @MainActor
  func testLeavingForegroundHidesPreviouslyRevealedTitles() async {
    let snapshot = SnapshotFixtures.titledSnapshot()
    let store = DashboardStore(provider: MockSnapshotProvider([.snapshot(snapshot)]))

    await store.refresh()
    store.toggleTitlePrivacy()
    XCTAssertTrue(store.revealFullConversationTitles)

    store.hideFullConversationTitles()

    XCTAssertFalse(store.revealFullConversationTitles)
    XCTAssertEqual(
      store.snapshot,
      snapshot,
      "Hiding titles must not discard the already validated snapshot."
    )
  }

  @MainActor
  func testAccountUnavailableClearsPreviousSnapshotAndTitleState() async {
    await assertAccountScopedStateIsCleared(after: .accountUnavailable)
  }

  @MainActor
  func testAccountChangedClearsPreviousSnapshotAndTitleState() async {
    await assertAccountScopedStateIsCleared(after: .accountChanged)
  }

  @MainActor
  private func assertAccountScopedStateIsCleared(
    after response: MockSnapshotProvider.Response,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let snapshot = SnapshotFixtures.titledSnapshot()
    let provider = MockSnapshotProvider([.snapshot(snapshot), response])
    let store = DashboardStore(provider: provider)

    await store.refresh()
    store.toggleTitlePrivacy()

    XCTAssertEqual(store.snapshot, snapshot, file: file, line: line)
    XCTAssertTrue(store.revealFullConversationTitles, file: file, line: line)

    await store.refresh()

    XCTAssertEqual(store.snapshot, .empty, file: file, line: line)
    XCTAssertFalse(store.fullTitlesAvailable, file: file, line: line)
    XCTAssertFalse(store.revealFullConversationTitles, file: file, line: line)
    XCTAssertFalse(store.isLiveActivityRunning, file: file, line: line)
    XCTAssertNotNil(store.errorMessage, file: file, line: line)
  }

  private func makeIsolatedUserDefaults() -> (UserDefaults, String) {
    let suiteName = "DashboardStoreTests.ExampleMode.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    return (userDefaults, suiteName)
  }
}
