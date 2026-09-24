import Foundation

final class LogBroker: @unchecked Sendable {
    typealias Sink = @Sendable (LogEntry) -> Void
    private let lock = NSLock()
    private var entries: [String: [LogEntry]] = [:]
    private var sinks: [String: [UUID: Sink]] = [:]
    private let limit = 500

    func append(projectID: String, level: String = "info", _ message: String) {
        let entry = LogEntry(id: UUID().uuidString, projectID: projectID, timestamp: .now, level: level, message: message)
        lock.lock()
        var list = entries[projectID, default: []]
        list.append(entry)
        if list.count > limit { list.removeFirst(list.count - limit) }
        entries[projectID] = list
        let current = Array(sinks[projectID, default: [:]].values)
        lock.unlock()
        for sink in current { sink(entry) }
    }

    func recent(projectID: String, limit requested: Int = 200) -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        let list = entries[projectID, default: []]
        return Array(list.suffix(max(1, min(requested, limit))))
    }

    @discardableResult
    func subscribe(projectID: String, sink: @escaping Sink) -> UUID {
        let id = UUID()
        lock.lock(); defer { lock.unlock() }
        sinks[projectID, default: [:]][id] = sink
        return id
    }

    func unsubscribe(projectID: String, id: UUID) {
        lock.lock(); defer { lock.unlock() }
        sinks[projectID]?[id] = nil
    }
}
