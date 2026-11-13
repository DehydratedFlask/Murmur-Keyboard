import os

/// Fixed names only: never attach keys, text, context, or field identifiers.
enum KeyboardPerformance {
    private static let signposter = OSSignposter(
        subsystem: "com.murmurkeyboard.app.keyboard", category: "Typing"
    )

    static func measure<T>(_ name: StaticString, _ operation: () throws -> T) rethrows -> T {
        let interval = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, interval) }
        return try operation()
    }
}
