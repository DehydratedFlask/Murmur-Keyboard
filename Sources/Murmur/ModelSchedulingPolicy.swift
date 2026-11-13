import Foundation

/// Value-only policy shared by the main-actor coordinator and model-free tests.
/// SDK objects never pass through this type.
struct ModelSchedulingPolicy<Selection: Equatable & Sendable> {
    enum Operation { case maintenance, finalRecognition, preview }

    private(set) var desiredSelection: Selection
    private(set) var pinnedSelection: Selection?
    private(set) var captureCount = 0
    private(set) var operation: Operation?
    private(set) var finalWaiterCount = 0

    init(selection: Selection) { desiredSelection = selection }

    var effectiveSelection: Selection { pinnedSelection ?? desiredSelection }
    var isSwitchDeferred: Bool { pinnedSelection.map { $0 != desiredSelection } ?? false }

    mutating func select(_ selection: Selection) { desiredSelection = selection }

    mutating func beginCapture() {
        if captureCount == 0 { pinnedSelection = desiredSelection }
        captureCount += 1
    }

    mutating func endCapture() {
        guard captureCount > 0 else { return }
        captureCount -= 1
        if captureCount == 0 { pinnedSelection = nil }
    }

    mutating func addFinalWaiter() { finalWaiterCount += 1 }
    mutating func removeFinalWaiter() { finalWaiterCount = max(0, finalWaiterCount - 1) }

    mutating func acquire(_ requested: Operation) -> Bool {
        guard operation == nil else { return false }
        if requested == .preview, finalWaiterCount > 0 { return false }
        operation = requested
        return true
    }

    mutating func release() { operation = nil }
}
