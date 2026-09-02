import XCTest
@testable import AgentIslandMobile

final class AgentSnapshotTests: XCTestCase {
  func testDefaultSyncRedactionRemovesFullTitlesButKeepsSafeSummaryAndUsage() {
    let source = SnapshotFixtures.titledSnapshot()

    let redacted = source.redactedForSync()

    XCTAssertFalse(redacted.sync.includesFullConversationTitles)
    XCTAssertNil(redacted.agents[0].conversations[0].title)
    XCTAssertEqual(
      redacted.agents[0].conversations[0].safeSummary,
      source.agents[0].conversations[0].safeSummary
    )
    XCTAssertEqual(redacted.usage, source.usage)
    XCTAssertEqual(redacted.activeConversationCount, 1)
  }

  func testExplicitTitleSyncOptInPreservesFullTitles() {
    let source = SnapshotFixtures.titledSnapshot()

    let optedIn = source.redactedForSync(includeFullConversationTitles: true)

    XCTAssertTrue(optedIn.sync.includesFullConversationTitles)
    XCTAssertEqual(
      optedIn.agents[0].conversations[0].title,
      source.agents[0].conversations[0].title
    )
  }

  func testValidatorRejectsDuplicateAgentIdentifiers() {
    var snapshot = SnapshotFixtures.titledSnapshot()
    snapshot.agents.append(snapshot.agents[0])

    XCTAssertThrowsError(try SnapshotValidator.validate(snapshot)) { error in
      XCTAssertEqual(error as? SnapshotValidationError, .duplicateIdentifier)
    }
  }

  func testValidatorRejectsDuplicateConversationIdentifiersAcrossAgents() {
    var snapshot = SnapshotFixtures.titledSnapshot()
    var secondAgent = snapshot.agents[0]
    secondAgent.id = "second-agent"
    secondAgent.displayName = "Second Agent"
    snapshot.agents.append(secondAgent)

    XCTAssertThrowsError(try SnapshotValidator.validate(snapshot)) { error in
      XCTAssertEqual(error as? SnapshotValidationError, .duplicateIdentifier)
    }
  }

  func testValidatorRejectsInvalidSourceDevice() {
    var snapshot = SnapshotFixtures.titledSnapshot()
    snapshot.sourceDevice.id = ""

    XCTAssertThrowsError(try SnapshotValidator.validate(snapshot)) { error in
      XCTAssertEqual(error as? SnapshotValidationError, .invalidSourceDevice)
    }
  }

  func testValidatorRejectsTitleWhenTitleSyncConsentFlagIsFalse() {
    var snapshot = SnapshotFixtures.titledSnapshot()
    snapshot.sync.includesFullConversationTitles = false

    XCTAssertThrowsError(try SnapshotValidator.validate(snapshot)) { error in
      XCTAssertEqual(error as? SnapshotValidationError, .undisclosedConversationTitle)
    }
  }

  func testValidatorRejectsControlCharactersInVisibleText() {
    var snapshot = SnapshotFixtures.titledSnapshot()
    snapshot.agents[0].displayName = "Codex\nHidden suffix"

    XCTAssertThrowsError(try SnapshotValidator.validate(snapshot)) { error in
      XCTAssertEqual(error as? SnapshotValidationError, .invalidText)
    }
  }

  func testValidatorRejectsFutureAgentTimestamp() {
    var snapshot = SnapshotFixtures.titledSnapshot(generatedAt: .now)
    snapshot.agents[0].updatedAt = Date().addingTimeInterval(6 * 60)

    XCTAssertThrowsError(try SnapshotValidator.validate(snapshot)) { error in
      XCTAssertEqual(error as? SnapshotValidationError, .invalidTimestamp)
    }
  }
}
