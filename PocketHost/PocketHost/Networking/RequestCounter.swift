import Foundation

final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var timestamps: [TimeInterval] = []

    func hit() {
        let now = Date().timeIntervalSince1970
        lock.lock(); defer { lock.unlock() }
        timestamps.append(now)
        timestamps.removeAll { now - $0 > 5 }
    }

    func rps() -> Double {
        let now = Date().timeIntervalSince1970
        lock.lock(); defer { lock.unlock() }
        timestamps.removeAll { now - $0 > 5 }
        return Double(timestamps.count) / 5.0
    }
}
