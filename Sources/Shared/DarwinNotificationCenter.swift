import Foundation

/// Lightweight wrapper around CFNotificationCenterGetDarwinNotifyCenter for
/// cross-process signaling between the main Murmur app and the keyboard extension.
///
/// Darwin notifications carry **no payload** — they are pure signals.
/// All data continues to live in the App Group UserDefaults via `SharedDefaults`.
///
/// Usage:
///   DarwinNotificationCenter.post(.transcriptionReady)
///   DarwinNotificationCenter.observe(.transcriptionReady) { /* read SharedDefaults */ }
enum DarwinNotificationCenter {

    // MARK: - Notification Names

    /// Well-known signal names shared between the app and the keyboard extension.
    enum Name: String, CaseIterable {
        /// Keyboard → App: "I've written a dictation request, please start recording."
        case dictationRequested = "com.murmur.darwin.dictationRequested"

        /// App → Keyboard: "Transcription result is ready in SharedDefaults."
        case transcriptionReady = "com.murmur.darwin.transcriptionReady"

        /// App → Keyboard: "Dictation was abandoned / failed."
        case dictationAbandoned = "com.murmur.darwin.dictationAbandoned"

        /// App → Keyboard: "Model readiness changed."
        case modelStateChanged = "com.murmur.darwin.modelStateChanged"

        var cfName: CFNotificationName {
            CFNotificationName(rawValue as CFString)
        }
    }

    // MARK: - Post

    /// Posts a Darwin notification visible to all processes in the same app group.
    static func post(_ name: Name) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name.cfName,
            nil,
            nil,
            true  // deliverImmediately
        )
    }

    // MARK: - Observe / Remove

    /// Callback storage — we need to prevent Swift closures from being collected
    /// while the C callback is still registered.
    /// Protected by `lock`; marked `nonisolated(unsafe)` to satisfy Swift 6
    /// global-state rules — all access is serialized through the lock.
    nonisolated(unsafe) private static var handlers: [String: () -> Void] = [:]
    private static let lock = NSLock()

    /// Registers a handler for a Darwin notification name.
    /// Only one handler per name is supported; calling again replaces the previous handler.
    /// The callback fires on an arbitrary thread — callers should dispatch to MainActor if needed.
    static func observe(_ name: Name, handler: @escaping () -> Void) {
        lock.lock()
        handlers[name.rawValue] = handler
        lock.unlock()

        let center = CFNotificationCenterGetDarwinNotifyCenter()

        // Remove any existing observer for this name first
        CFNotificationCenterRemoveObserver(
            center,
            nil,
            name.cfName,
            nil
        )

        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, cfName, _, _ in
                guard let cfName else { return }
                let key = cfName.rawValue as String
                DarwinNotificationCenter.lock.lock()
                let callback = DarwinNotificationCenter.handlers[key]
                DarwinNotificationCenter.lock.unlock()
                callback?()
            },
            name.rawValue as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// Removes the observer for a given Darwin notification name.
    static func removeObserver(_ name: Name) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveObserver(center, nil, name.cfName, nil)

        lock.lock()
        handlers.removeValue(forKey: name.rawValue)
        lock.unlock()
    }

    /// Removes all observers registered through this helper.
    static func removeAllObservers() {
        lock.lock()
        let names = Array(handlers.keys)
        handlers.removeAll()
        lock.unlock()

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for key in names {
            let cfName = CFNotificationName(key as CFString)
            CFNotificationCenterRemoveObserver(center, nil, cfName, nil)
        }
    }
}
