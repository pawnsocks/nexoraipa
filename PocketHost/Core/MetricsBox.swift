import Foundation

final class MetricsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = MetricsSnapshot()

    func set(_ value: MetricsSnapshot) {
        lock.lock(); defer { lock.unlock() }
        snapshot = value
    }

    func get() -> MetricsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }
}
