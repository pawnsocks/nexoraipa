import Foundation

struct ProjectBackup: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let projectID: String
    let createdAt: Date
    let label: String
    let sizeBytes: Int64
}

final class BackupManager: @unchecked Sendable {
    enum BackupError: Error, LocalizedError {
        case projectMissing
        case backupMissing
        case copyFailed

        var errorDescription: String? {
            switch self {
            case .projectMissing: return "Project not found."
            case .backupMissing: return "Backup not found."
            case .copyFailed: return "Could not copy project files."
            }
        }
    }

    private let projects: ProjectManager
    private let history: HistoryStore
    private let fm = FileManager.default

    init(projects: ProjectManager, history: HistoryStore) {
        self.projects = projects
        self.history = history
    }

    func create(projectID: String, label: String = "Manual backup") throws -> ProjectBackup {
        guard projects.get(projectID) != nil else { throw BackupError.projectMissing }
        let id = UUID().uuidString.lowercased()
        let root = backupRoot(projectID)
        let folder = root.appendingPathComponent(id, isDirectory: true)
        let snapshot = folder.appendingPathComponent("workspace", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.copyItem(at: projects.workspaceURL(projectID), to: snapshot)

        let size = directorySize(snapshot)
        let backup = ProjectBackup(id: id, projectID: projectID, createdAt: .now, label: label, sizeBytes: size)
        let data = try JSONEncoder.nexora.encode(backup)
        try data.write(to: folder.appendingPathComponent("backup.json"), options: .atomic)
        history.append(projectID: projectID, kind: .backup, title: "Backup created", detail: label)
        return backup
    }

    func list(projectID: String) -> [ProjectBackup] {
        let root = backupRoot(projectID)
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("backup.json")) else { return nil }
            return try? JSONDecoder.nexora.decode(ProjectBackup.self, from: data)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func restore(projectID: String, backupID: String) throws {
        guard projects.get(projectID) != nil else { throw BackupError.projectMissing }
        let source = backupRoot(projectID).appendingPathComponent(backupID, isDirectory: true).appendingPathComponent("workspace", isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { throw BackupError.backupMissing }
        let target = projects.workspaceURL(projectID)
        try? fm.removeItem(at: target)
        try fm.copyItem(at: source, to: target)
        projects.touch(projectID)
        history.append(projectID: projectID, kind: .backup, title: "Backup restored", detail: backupID)
    }

    func delete(projectID: String, backupID: String) throws {
        let folder = backupRoot(projectID).appendingPathComponent(backupID, isDirectory: true)
        guard fm.fileExists(atPath: folder.path) else { throw BackupError.backupMissing }
        try fm.removeItem(at: folder)
    }

    func totalBytes() -> Int64 {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NexoraHost", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
        return directorySize(base)
    }

    private func backupRoot(_ projectID: String) -> URL {
        projects.workspaceURL(projectID)
            .deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true)
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

private extension JSONEncoder {
    static var nexora: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        return value
    }
}

private extension JSONDecoder {
    static var nexora: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}
