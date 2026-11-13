import XCTest
#if canImport(Murmur)
@testable import Murmur
#else
@testable import MurmurTextProcessing
#endif

@MainActor
final class TranscriptionServiceTests: XCTestCase {
    func testConcurrentLoadCallersShareOneLoad() async throws {
        let preferences = PreferencesSnapshot()
        defer { preferences.restore() }
        let backend = ControlledModelBackend()
        let service = makeService(backend)
        let first = Task { await service.loadModel() }
        let second = Task { await service.loadModel() }
        try await waitUntil { await backend.loadCount == 1 }
        await backend.finishLoad()
        await first.value
        await second.value
        XCTAssertEqual(service.modelState, .loaded)
        XCTAssertEqual(service.activeModelLabel, "Whisper Tiny")
        let snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.loads.count, 1)
        XCTAssertEqual(snapshot.maximumConcurrentOperations, 1)
        XCTAssertFalse(snapshot.overlappedUnload)
    }

    func testSupersededLoadNeverPublishesReadyAndLoadsNewestChoice() async throws {
        let preferences = PreferencesSnapshot()
        defer { preferences.restore() }
        let backend = ControlledModelBackend()
        let service = makeService(backend)
        let loading = Task { await service.loadModel() }
        try await waitUntil { await backend.loadCount == 1 }
        service.selectedModel = .base
        await backend.finishLoad()
        try await waitUntil { await backend.loadCount == 2 }
        XCTAssertEqual(service.modelState, .loading)
        XCTAssertNil(service.activeModelLabel)
        await backend.finishLoad()
        await loading.value
        XCTAssertEqual(service.activeModelLabel, "Whisper Base")
        let snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.loads.map(\.whisperModel), [.tiny, .base])
        XCTAssertFalse(snapshot.overlappedUnload)
        XCTAssertEqual(snapshot.maximumConcurrentOperations, 1)
    }

    func testOfflineFailureReachesCallerAndExplicitRetryCanSucceed() async throws {
        let preferences = PreferencesSnapshot()
        defer { preferences.restore() }
        let backend = ControlledModelBackend()
        let service = makeService(backend)
        let recognition = Task { try await service.transcribe(audioURL: Self.audioURL, languageCode: nil) }
        try await waitUntil { await backend.loadCount == 1 }
        await backend.finishLoad(error: FakeFailure.offline)
        do {
            _ = try await recognition.value
            XCTFail("Offline load failure must reach recognition")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("internet"))
        }
        XCTAssertTrue(service.modelState.isError)
        XCTAssertEqual(service.readinessStage, .failed)
        let retry = Task { await service.loadModel() }
        try await waitUntil { await backend.loadCount == 2 }
        await backend.finishLoad()
        await retry.value
        XCTAssertEqual(service.modelState, .loaded)
        XCTAssertEqual(service.cachedModelBytes, 1234)
    }

    func testCancellationWhileWaitingDoesNotCancelSharedLoad() async throws {
        let preferences = PreferencesSnapshot()
        defer { preferences.restore() }
        let backend = ControlledModelBackend()
        let service = makeService(backend)
        let recognition = Task { try await service.transcribe(audioURL: Self.audioURL, languageCode: nil) }
        try await waitUntil { await backend.loadCount == 1 }
        recognition.cancel()
        do {
            _ = try await recognition.value
            XCTFail("Readiness wait must be cancellable")
        } catch is CancellationError {
            // The fake SDK still owns its in-flight noncancellable load.
        }
        XCTAssertEqual(service.modelState, .loading)
        await backend.finishLoad()
        try await waitUntil { service.modelState == .loaded }
        let snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.loads.count, 1)
        XCTAssertEqual(snapshot.recognitionCount, 0)
    }

    func testUnloadDuringLoadWaitsForSDKBeforeReleasingResources() async throws {
        let preferences = PreferencesSnapshot()
        defer { preferences.restore() }
        let backend = ControlledModelBackend()
        let service = makeService(backend)
        let loading = Task { await service.loadModel() }
        try await waitUntil { await backend.loadCount == 1 }
        let unloading = Task { await service.unloadModel() }
        // Flush the main actor and inspect the backend while the SDK is suspended.
        await Task.yield()
        var snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.activeOperationCount, 1)
        XCTAssertFalse(snapshot.overlappedUnload)
        await backend.finishLoad()
        await loading.value
        await unloading.value
        snapshot = await backend.snapshot()
        XCTAssertEqual(service.modelState, .unloaded)
        XCTAssertNil(service.activeModelLabel)
        XCTAssertFalse(snapshot.overlappedUnload)
        XCTAssertEqual(snapshot.activeOperationCount, 0)
    }

    func testCaptureLeaseDefersSwitchAndUnloadUntilFinalCompletion() async throws {
        let preferences = PreferencesSnapshot()
        defer { preferences.restore() }
        let backend = ControlledModelBackend()
        let service = makeService(backend)
        let loading = Task { await service.loadModel() }
        try await waitUntil { await backend.loadCount == 1 }
        await backend.finishLoad()
        await loading.value
        service.beginCapture()
        service.selectedModel = .base
        XCTAssertTrue(service.isModelSwitchDeferred)
        XCTAssertEqual(service.activeModelLabel, "Whisper Tiny")
        let final = Task { try await service.transcribe(audioURL: Self.audioURL, languageCode: "en") }
        try await waitUntil { await backend.recognitionCount == 1 }
        let preview = try await service.transcribePreview(audioURL: Self.audioURL, languageCode: nil)
        XCTAssertNil(preview)
        let unloading = Task { await service.unloadModel() }
        await Task.yield()
        let snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.loads.count, 1)
        XCTAssertEqual(snapshot.activeOperationCount, 1)
        XCTAssertFalse(snapshot.overlappedUnload)
        await backend.finishRecognition()
        let result = try await final.value
        XCTAssertEqual(result, "test transcript")
        XCTAssertEqual(service.activeModelLabel, "Whisper Tiny")
        service.endCapture()
        await unloading.value
        XCTAssertEqual(service.modelState, .unloaded)
        XCTAssertFalse(service.isModelSwitchDeferred)
        let completed = await backend.snapshot()
        XCTAssertEqual(completed.loads.count, 1)
        XCTAssertFalse(completed.overlappedUnload)
    }

    private static let audioURL = URL(fileURLWithPath: "/tmp/murmur-test-never-read.wav")

    private func makeService(_ backend: ControlledModelBackend) -> TranscriptionService {
        UserDefaults.standard.set(TranscriptionEngine.whisper.rawValue, forKey: TranscriptionEngine.storageKey)
        UserDefaults.standard.set(WhisperModel.tiny.rawValue, forKey: "selectedWhisperModel")
        return TranscriptionService(runtime: backend)
    }

    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            if ContinuousClock.now >= deadline {
                XCTFail("Coordinator did not reach expected state", file: file, line: line)
                throw FakeFailure.timeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct PreferencesSnapshot {
    let engine = UserDefaults.standard.object(forKey: TranscriptionEngine.storageKey)
    let model = UserDefaults.standard.object(forKey: "selectedWhisperModel")

    func restore() {
        UserDefaults.standard.set(engine, forKey: TranscriptionEngine.storageKey)
        UserDefaults.standard.set(model, forKey: "selectedWhisperModel")
    }
}

private enum FakeFailure: LocalizedError {
    case offline, timeout
    var errorDescription: String? {
        switch self {
        case .offline: return "Network is offline"
        case .timeout: return "Test coordination timeout"
        }
    }
}

private actor ControlledModelBackend: ModelRuntimeBackend {
    struct Snapshot: Sendable {
        let loads: [ModelSelection]
        let recognitionCount: Int
        let activeOperationCount: Int
        let maximumConcurrentOperations: Int
        let overlappedUnload: Bool
    }

    private var loads: [ModelSelection] = []
    private(set) var recognitionCount = 0
    private var activeOperationCount = 0
    private var maximumConcurrentOperations = 0
    private var overlappedUnload = false
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var recognitionContinuation: CheckedContinuation<Void, Error>?

    var loadCount: Int { loads.count }

    func load(_ selection: ModelSelection, progress: @escaping @Sendable (ModelRuntimeProgress) -> Void) async throws {
        beginOperation()
        defer { activeOperationCount -= 1 }
        loads.append(selection)
        progress(.init(stage: .loading))
        // Deliberately noncancellable, like SDK work that must finish before its
        // model memory can safely be released.
        try await withCheckedThrowingContinuation { loadContinuation = $0 }
    }

    func unload() async {
        if activeOperationCount > 0 { overlappedUnload = true }
    }

    func transcribe(audioURL: URL, languageCode: String?, prompt: String?) async throws -> String {
        beginOperation()
        defer { activeOperationCount -= 1 }
        recognitionCount += 1
        try await withCheckedThrowingContinuation { recognitionContinuation = $0 }
        return "test transcript"
    }

    func cachedBytes() async -> Int64 { 1234 }

    func finishLoad(error: Error? = nil) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    func finishRecognition() {
        recognitionContinuation?.resume()
        recognitionContinuation = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(loads: loads, recognitionCount: recognitionCount, activeOperationCount: activeOperationCount,
                 maximumConcurrentOperations: maximumConcurrentOperations, overlappedUnload: overlappedUnload)
    }

    private func beginOperation() {
        activeOperationCount += 1
        maximumConcurrentOperations = max(maximumConcurrentOperations, activeOperationCount)
    }
}
