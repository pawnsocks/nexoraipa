import Foundation

struct ProjectHistoryEvent: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case fileChanged
        case projectRun
        case runtimeFailed
        case gitImport
        case gitCommit
        case aiEdit
        case checkpoint
        case backup
        case webhook
        case automation
    }

    let id: String
    let projectID: String
    let kind: Kind
    let title: String
    let detail: String?
    let timestamp: Date
}

final class HistoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private var events: [ProjectHistoryEvent] = []
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NexoraHost", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history.json")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func append(projectID: String, kind: ProjectHistoryEvent.Kind, title: String, detail: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        events.append(.init(
            id: UUID().uuidString,
            projectID: projectID,
            kind: kind,
            title: title,
            detail: detail,
            timestamp: .now
        ))
        if events.count > 2_000 { events.removeFirst(events.count - 2_000) }
        persistLocked()
    }

    func list(projectID: String? = nil, limit: Int = 250) -> [ProjectHistoryEvent] {
        lock.lock(); defer { lock.unlock() }
        let filtered = projectID.map { id in events.filter { $0.projectID == id } } ?? events
        return Array(filtered.sorted { $0.timestamp > $1.timestamp }.prefix(max(1, limit)))
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), let decoded = try? decoder.decode([ProjectHistoryEvent].self, from: data) else { return }
        events = decoded
    }

    private func persistLocked() {
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
