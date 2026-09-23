import Foundation

final class KeyValueStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func set(_ key: String, value: Data) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    func get(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func delete(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return values.count
    }

    func keys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return values.keys.sorted()
    }
}
