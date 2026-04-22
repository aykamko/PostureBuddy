import Foundation
import os

/// Timestamped `print`-style logger. Thread-safe — DateFormatter is guarded by a
/// lock because `captureOutput` on the video queue and the main-actor coach both
/// log frequently.
nonisolated enum Log {
    static func line(_ tag: String, _ message: String) {
        print("\(timestamp()) \(tag) \(message)")
    }

    private static let formatter: OSAllocatedUnfairLock<DateFormatter> = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return OSAllocatedUnfairLock(initialState: f)
    }()

    private static func timestamp() -> String {
        formatter.withLock { $0.string(from: Date()) }
    }
}
