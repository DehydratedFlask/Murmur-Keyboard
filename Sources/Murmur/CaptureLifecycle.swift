import Foundation

/// Value-only ownership for async capture. Model readiness deliberately isn't a
/// prerequisite: audio is durable before recognition can become available.
struct CaptureLifecycle: Sendable {
    enum Phase: Equatable, Sendable { case starting, recording, paused, processing }
    struct Operation: Equatable, Sendable {
        let id: UUID
        let sessionID: String?
        var phase: Phase
    }
    private(set) var operation: Operation?

    mutating func begin(sessionID: String?) -> UUID? {
        guard operation == nil else { return nil }
        let operation = Operation(id: UUID(), sessionID: sessionID, phase: .starting)
        self.operation = operation
        return operation.id
    }

    @discardableResult
    mutating func move(_ id: UUID, to phase: Phase) -> Bool {
        guard var current = operation, current.id == id else { return false }
        let allowed: Bool
        switch (current.phase, phase) {
        case (.starting, .recording), (.starting, .processing),
             (.recording, .paused), (.paused, .recording),
             (.recording, .processing), (.paused, .processing): allowed = true
        default: allowed = false
        }
        guard allowed else { return false }
        current.phase = phase
        operation = current
        return true
    }

    func owns(_ id: UUID) -> Bool { operation?.id == id }

    func canDeliver(_ id: UUID, to sessionID: String?) -> Bool {
        guard let operation, operation.id == id, operation.phase == .processing,
              let expected = operation.sessionID else { return false }
        return sessionID == expected
    }

    mutating func finish(_ id: UUID) {
        guard owns(id) else { return }
        operation = nil
    }
}
