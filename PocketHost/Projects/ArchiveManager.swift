import Foundation
import ZIPFoundation

final class ArchiveManager: @unchecked Sendable {
    enum ArchiveError: Error, LocalizedError {
        case invalidArchive
        case tooLarge
        case noFiles

        var errorDescription: String? {
            switch self {
            case .invalidArchive: return "The ZIP archive could not be opened."
            case .tooLarge: return "The ZIP archive is too large for the current mobile import limit."
            case .noFiles: return "The ZIP archive does not contain project files."
            }
        }
    }

    private let fm = FileManager.default

    func exportProject(projectID: String, projects: ProjectManager) throws -> URL {
        guard let project = projects.get(projectID) else { throw ProjectManager.ProjectError.notFound }
        let safeName = project.name.replacingOccurrences(of: "/", with: "-")
        let target = fm.temporaryDirectory.appendingPathComponent("\(safeName)-Nexora.zip")
        try? fm.removeItem(at: target)
        try fm.zipItem(at: projects.workspaceURL(projectID), to: target, shouldKeepParent: false, compressionMethod: .deflate)
        return target
    }

    func importZIP(url: URL, name: String?, projects: ProjectManager, history: HistoryStore) throws -> ProjectRecord {
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("nexora-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try fm.unzipItem(at: url, to: tempRoot)

        let source = normalizedRoot(tempRoot)
        let files = try collectFiles(source)
        guard !files.isEmpty else { throw ArchiveError.noFiles }
        let total = files.reduce(0) { $0 + $1.data.count }
        guard total <= 50 * 1024 * 1024 else { throw ArchiveError.tooLarge }

        let detection = detectRuntime(paths: files.map(\.path))
        let projectName = name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? url.deletingPathExtension().lastPathComponent
        let project = try projects.create(name: projectName, runtime: detection.runtime, entrypoint: nil)
        do {
            for file in files {
                let content: String
                let encoding: String
                if let text = String(data: file.data, encoding: .utf8) {
                    content = text
                    encoding = "utf8"
                } else {
                    content = file.data.base64EncodedString()
                    encoding = "base64"
                }
                _ = try projects.writeFile(projectID: project.id, path: file.path, request: .init(content: content, encoding: encoding))
            }
            let entry = files.contains(where: { $0.path == detection.entrypoint }) ? detection.entrypoint : project.entrypoint
            let updated = try projects.updateConfiguration(project.id, runtime: detection.runtime, entrypoint: entry)
            history.append(projectID: project.id, kind: .fileChanged, title: "ZIP imported", detail: url.lastPathComponent)
            return updated
        } catch {
            try? projects.delete(project.id)
            throw error
        }
    }

    private func normalizedRoot(_ root: URL) -> URL {
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]), items.count == 1,
              let values = try? items[0].resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true else { return root }
        return items[0]
    }

    private func collectFiles(_ root: URL) throws -> [(path: String, data: Data)] {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        var output: [(String, Data)] = []
        var total = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            total += size
            guard total <= 50 * 1024 * 1024 else { throw ArchiveError.tooLarge }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if relative.hasPrefix(".git/") || relative.hasPrefix(".nexora/") { continue }
            output.append((relative, try Data(contentsOf: url)))
        }
        return output
    }

    private func detectRuntime(paths: [String]) -> (runtime: RuntimeKind, entrypoint: String) {
        let set = Set(paths)
        if set.contains("main.py") { return (.python, "main.py") }
        if set.contains("app.py") { return (.python, "app.py") }
        if set.contains("main.lua") { return (.lua, "main.lua") }
        if set.contains("index.ts") { return (.typescript, "index.ts") }
        if set.contains("index.js") { return (.javascript, "index.js") }
        if set.contains("main.js") { return (.javascript, "main.js") }
        if set.contains("index.html") { return (.javascript, "index.html") }
        if let py = paths.first(where: { $0.hasSuffix(".py") }) { return (.python, py) }
        if let lua = paths.first(where: { $0.hasSuffix(".lua") }) { return (.lua, lua) }
        if let ts = paths.first(where: { $0.hasSuffix(".ts") }) { return (.typescript, ts) }
        if let js = paths.first(where: { $0.hasSuffix(".js") }) { return (.javascript, js) }
        return (.javascript, "index.js")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
