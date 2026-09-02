import XCTest
@testable import AgentIslandMobile

final class DashboardStoreTests: XCTestCase {
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
}
