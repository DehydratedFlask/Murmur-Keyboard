import XCTest
@testable import MurmurTextProcessing

final class CaptureLifecycleTests: XCTestCase {
    func testColdCaptureDoesNotRequireModelReadinessAndRejectsDuplicateStart() throws {
        var lifecycle = CaptureLifecycle()
        let id = try XCTUnwrap(lifecycle.begin(sessionID: "keyboard-one"))
        XCTAssertNil(lifecycle.begin(sessionID: "duplicate"))
        XCTAssertTrue(lifecycle.move(id, to: .recording))
        XCTAssertTrue(lifecycle.move(id, to: .processing))
        XCTAssertTrue(lifecycle.canDeliver(id, to: "keyboard-one"))
    }

    func testPauseResumeAndFinishWhilePaused() throws {
        var lifecycle = CaptureLifecycle()
        let id = try XCTUnwrap(lifecycle.begin(sessionID: nil))
        XCTAssertTrue(lifecycle.move(id, to: .recording))
        XCTAssertTrue(lifecycle.move(id, to: .paused))
        XCTAssertTrue(lifecycle.move(id, to: .recording))
        XCTAssertTrue(lifecycle.move(id, to: .paused))
        XCTAssertTrue(lifecycle.move(id, to: .processing))
        XCTAssertFalse(lifecycle.move(id, to: .recording))
    }

    func testCanceledCompletionCannotAffectNewCaptureOrInsertInNewSession() throws {
        var lifecycle = CaptureLifecycle()
        let old = try XCTUnwrap(lifecycle.begin(sessionID: "old-field"))
        lifecycle.finish(old)
        let fresh = try XCTUnwrap(lifecycle.begin(sessionID: "new-field"))
        XCTAssertFalse(lifecycle.move(old, to: .processing))
        lifecycle.finish(old)
        XCTAssertTrue(lifecycle.owns(fresh))
        XCTAssertFalse(lifecycle.canDeliver(old, to: "new-field"))
    }

    func testRetriesSaveWithoutReturningToAnOldFieldAndDeliveryMatchesOnlyActiveSession() throws {
        var lifecycle = CaptureLifecycle()
        let original = try XCTUnwrap(lifecycle.begin(sessionID: "original-field"))
        XCTAssertTrue(lifecycle.move(original, to: .processing))
        XCTAssertFalse(lifecycle.canDeliver(original, to: "different-field"))
        lifecycle.finish(original)
        let retry = try XCTUnwrap(lifecycle.begin(sessionID: nil))
        XCTAssertTrue(lifecycle.move(retry, to: .processing))
        XCTAssertFalse(lifecycle.canDeliver(retry, to: "original-field"))
        XCTAssertFalse(lifecycle.canDeliver(retry, to: nil))
    }
}
