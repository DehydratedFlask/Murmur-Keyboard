import XCTest
@testable import MurmurTextProcessing

final class ModelSchedulingPolicyTests: XCTestCase {
    func testSelectionChangesApplyImmediatelyWhenIdle() {
        var policy = ModelSchedulingPolicy(selection: "tiny")
        policy.select("base")
        XCTAssertEqual(policy.effectiveSelection, "base")
        XCTAssertFalse(policy.isSwitchDeferred)
    }

    func testRecordingPinsSelectionUntilFinalLeaseEnds() {
        var policy = ModelSchedulingPolicy(selection: "tiny")
        policy.beginCapture()
        policy.beginCapture() // final processing has its own nested lease
        policy.select("base")
        XCTAssertEqual(policy.effectiveSelection, "tiny")
        XCTAssertTrue(policy.isSwitchDeferred)
        policy.endCapture()
        XCTAssertEqual(policy.effectiveSelection, "tiny")
        policy.endCapture()
        XCTAssertEqual(policy.effectiveSelection, "base")
        XCTAssertFalse(policy.isSwitchDeferred)
    }

    func testIntermediateChoicesCoalesceToMostRecentSelection() {
        var policy = ModelSchedulingPolicy(selection: "tiny")
        policy.beginCapture()
        policy.select("base")
        policy.select("parakeet")
        policy.select("base")
        policy.endCapture()
        XCTAssertEqual(policy.effectiveSelection, "base")
    }

    func testNoUnloadOrSecondDecodeWhileRecognitionOwnsResources() {
        var policy = ModelSchedulingPolicy(selection: "tiny")
        XCTAssertTrue(policy.acquire(.finalRecognition))
        XCTAssertFalse(policy.acquire(.maintenance))
        XCTAssertFalse(policy.acquire(.preview))
        XCTAssertFalse(policy.acquire(.finalRecognition))
        policy.release()
        XCTAssertTrue(policy.acquire(.maintenance))
    }

    func testPreviewNeverQueuesAheadOfFinalWaiter() {
        var policy = ModelSchedulingPolicy(selection: "tiny")
        policy.addFinalWaiter()
        XCTAssertFalse(policy.acquire(.preview))
        // Readiness work is allowed while final is waiting for its model.
        XCTAssertTrue(policy.acquire(.maintenance))
        policy.release()
        XCTAssertTrue(policy.acquire(.finalRecognition))
        policy.release()
        policy.removeFinalWaiter()
        XCTAssertTrue(policy.acquire(.preview))
    }

    func testCancelledWaiterAndExtraEndDoNotBreakFutureCapture() {
        var policy = ModelSchedulingPolicy(selection: "tiny")
        policy.addFinalWaiter()
        policy.removeFinalWaiter()
        policy.removeFinalWaiter()
        policy.endCapture()
        policy.select("base")
        policy.beginCapture()
        policy.select("tiny")
        XCTAssertEqual(policy.captureCount, 1)
        XCTAssertEqual(policy.finalWaiterCount, 0)
        XCTAssertEqual(policy.effectiveSelection, "base")
    }
}
