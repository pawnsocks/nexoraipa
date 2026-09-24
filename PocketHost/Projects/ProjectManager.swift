import Foundation

final class ProjectManager: @unchecked Sendable {
    enum ProjectError: Error { case invalidName, notFound, invalidPath, invalidRuntime, entrypointMissing }

    private let lock = NSLock()
    private var projects: [String: ProjectRecord] = [:]
    private var deployments: [String: [DeploymentRecord]] = [:]
    private let root: URL
    private let stateFile: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let logs: LogBroker

    init(logs: LogBroker) {
        self.logs = logs
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NexoraHost", isDirectory: true)
        root = base.appendingPathComponent("Projects", isDirectory: true)
        stateFile = base.appendingPathComponent("projects.json")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    func list() -> [ProjectRecord] {
        lock.lock(); defer { lock.unlock() }
        return projects.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func get(_ id: String) -> ProjectRecord? {
        lock.lock(); defer { lock.unlock() }
        return projects[id]
    }

    func create(name: String, runtime: RuntimeKind, entrypoint: String?) throws -> ProjectRecord {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty && clean.count <= 80 else { throw ProjectError.invalidName }

        let id = UUID().uuidString.lowercased()
        let entry = try sanitize(relativePath: entrypoint ?? runtime.defaultEntrypoint)
        let now = Date()
        let record = ProjectRecord(
            id: id,
            name: clean,
            runtime: runtime,
            entrypoint: entry,
            state: .stopped,
            activeDeploymentID: nil,
            createdAt: now,
            updatedAt: now
        )

        try FileManager.default.createDirectory(at: workspaceURL(id), withIntermediateDirectories: true)
        let starter = workspaceURL(id).appendingPathComponent(entry)
        try FileManager.default.createDirectory(at: starter.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(runtime.starterSource.utf8).write(to: starter, options: .atomic)

        let readme = workspaceURL(id).appendingPathComponent("README.md")
        let readmeText = """
        # \(clean)

        Runtime: \(runtime.rawValue)
        Entry point: \(entry)
        Mode: \(runtime.supportMode.rawValue)

        Created by Nexora Host.
        """
        try Data(readmeText.utf8).write(to: readme, options: .atomic)

        lock.lock()
        projects[id] = record
        persistLocked()
        lock.unlock()

        logs.append(projectID: id, "Project created with \(entry)")
        return record
    }

    func delete(_ id: String) throws {
        lock.lock()
        guard projects.removeValue(forKey: id) != nil else {
            lock.unlock()
            throw ProjectError.notFound
        }
        deployments[id] = nil
        persistLocked()
        lock.unlock()
        try? FileManager.default.removeItem(at: projectURL(id))
    }

    func setState(_ id: String, _ state: ProjectRecord.State) throws -> ProjectRecord {
        lock.lock(); defer { lock.unlock() }
        guard var project = projects[id] else { throw ProjectError.notFound }
        project.state = state
        project.updatedAt = .now
        projects[id] = project
        persistLocked()
        return project
    }

    func touch(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard var project = projects[id] else { return }
        project.updatedAt = .now
        projects[id] = project
        persistLocked()
    }

    func deploy(projectID: String, request: CreateDeploymentRequest) throws -> DeploymentRecord {
        guard var project = get(projectID) else { throw ProjectError.notFound }

        if let raw = request.runtime {
            guard let runtime = RuntimeKind.apiValue(raw) else { throw ProjectError.invalidRuntime }
            project.runtime = runtime
        }
        if let entry = request.entrypoint {
            project.entrypoint = try sanitize(relativePath: entry)
        }

        let deploymentID = UUID().uuidString.lowercased()
        let release = projectURL(projectID)
            .appendingPathComponent("releases", isDirectory: true)
            .appendingPathComponent(deploymentID, isDirectory: true)
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)

        var total = 0
        for file in request.files {
            let relative = try sanitize(relativePath: file.path)
            let data: Data
            switch (file.encoding ?? "utf8").lowercased() {
            case "utf8", "text":
                data = Data(file.content.utf8)
            case "base64":
                guard let decoded = Data(base64Encoded: file.content) else { throw ProjectError.invalidPath }
                data = decoded
            default:
                throw ProjectError.invalidPath
            }

            total += data.count
            guard total <= 25 * 1024 * 1024 else { throw ProjectError.invalidPath }

            let target = release.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }

        let entryURL = release.appendingPathComponent(project.entrypoint)
        guard FileManager.default.fileExists(atPath: entryURL.path) else { throw ProjectError.entrypointMissing }

        let workspace = workspaceURL(projectID)
        try? FileManager.default.removeItem(at: workspace)
        try FileManager.default.copyItem(at: release, to: workspace)

        project.activeDeploymentID = deploymentID
        project.state = .stopped
        project.updatedAt = .now

        let record = DeploymentRecord(
            id: deploymentID,
            projectID: projectID,
            createdAt: .now,
            fileCount: request.files.count,
            totalBytes: total,
            entrypoint: project.entrypoint,
            runtime: project.runtime
        )

        lock.lock()
        projects[projectID] = project
        deployments[projectID, default: []].append(record)
        persistLocked()
        lock.unlock()

        logs.append(projectID: projectID, "Deployment \(deploymentID) activated (\(request.files.count) files)")
        return record
    }

    func listDeployments(_ projectID: String) throws -> [DeploymentRecord] {
        guard get(projectID) != nil else { throw ProjectError.notFound }
        lock.lock(); defer { lock.unlock() }
        return deployments[projectID, default: []].sorted { $0.createdAt > $1.createdAt }
    }

    func entrypointSource(_ projectID: String) throws -> (ProjectRecord, String) {
        guard let project = get(projectID) else { throw ProjectError.notFound }
        let url = workspaceURL(projectID).appendingPathComponent(try sanitize(relativePath: project.entrypoint))
        guard let data = FileManager.default.contents(atPath: url.path),
              let source = String(data: data, encoding: .utf8) else {
            throw ProjectError.entrypointMissing
        }
        return (project, source)
    }

    func listFiles(projectID: String, path: String = "") throws -> [ProjectFileInfo] {
        guard get(projectID) != nil else { throw ProjectError.notFound }
        let relative = try sanitize(relativePath: path, allowEmpty: true)
        let dir = workspaceURL(projectID).appendingPathComponent(relative)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProjectError.invalidPath
        }

        return try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).map { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let rel = url.path.replacingOccurrences(of: workspaceURL(projectID).path + "/", with: "")
            return ProjectFileInfo(
                path: rel,
                name: url.lastPathComponent,
                isDirectory: values.isDirectory ?? false,
                size: values.fileSize ?? 0
            )
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func readFile(projectID: String, path: String) throws -> ProjectFileResponse {
        guard get(projectID) != nil else { throw ProjectError.notFound }
        let relative = try sanitize(relativePath: path)
        let data = try Data(contentsOf: workspaceURL(projectID).appendingPathComponent(relative))
        if let text = String(data: data, encoding: .utf8) {
            return .init(path: relative, content: text, encoding: "utf8")
        }
        return .init(path: relative, content: data.base64EncodedString(), encoding: "base64")
    }

    func writeFile(projectID: String, path: String, request: FileWriteRequest) throws -> ProjectFileResponse {
        guard get(projectID) != nil else { throw ProjectError.notFound }
        let relative = try sanitize(relativePath: path)

        let data: Data
        switch (request.encoding ?? "utf8").lowercased() {
        case "utf8", "text":
            data = Data(request.content.utf8)
        case "base64":
            guard let decoded = Data(base64Encoded: request.content) else { throw ProjectError.invalidPath }
            data = decoded
        default:
            throw ProjectError.invalidPath
        }

        guard data.count <= 5 * 1024 * 1024 else { throw ProjectError.invalidPath }

        let target = workspaceURL(projectID).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        touch(projectID)
        logs.append(projectID: projectID, "Updated file \(relative)")
        return try readFile(projectID: projectID, path: relative)
    }

    func createDirectory(projectID: String, path: String) throws {
        guard get(projectID) != nil else { throw ProjectError.notFound }
        let relative = try sanitize(relativePath: path)
        let target = workspaceURL(projectID).appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        touch(projectID)
        logs.append(projectID: projectID, "Created folder \(relative)")
    }

    func deleteFile(projectID: String, path: String) throws {
        guard get(projectID) != nil else { throw ProjectError.notFound }
        let relative = try sanitize(relativePath: path)
        guard relative != get(projectID)?.entrypoint else { throw ProjectError.invalidPath }
        try FileManager.default.removeItem(at: workspaceURL(projectID).appendingPathComponent(relative))
        touch(projectID)
        logs.append(projectID: projectID, "Deleted \(relative)")
    }

    func duplicateProject(_ id: String, name: String? = nil) throws -> ProjectRecord {
        guard let sourceProject = get(id) else { throw ProjectError.notFound }
        let newName = name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? name!.trimmingCharacters(in: .whitespacesAndNewlines)
            : sourceProject.name + " Copy"
        let duplicate = try create(name: newName, runtime: sourceProject.runtime, entrypoint: sourceProject.entrypoint)
        let source = workspaceURL(id)
        let target = workspaceURL(duplicate.id)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
        try? FileManager.default.removeItem(at: target.appendingPathComponent(".nexora", isDirectory: true))
        let updated = try updateConfiguration(duplicate.id, runtime: sourceProject.runtime, entrypoint: sourceProject.entrypoint)
        logs.append(projectID: duplicate.id, "Duplicated from \(sourceProject.name)")
        return updated
    }

    func renameProject(_ id: String, name: String) throws -> ProjectRecord {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty && clean.count <= 80 else { throw ProjectError.invalidName }
        lock.lock(); defer { lock.unlock() }
        guard var project = projects[id] else { throw ProjectError.notFound }
        project.name = clean
        project.updatedAt = .now
        projects[id] = project
        persistLocked()
        return project
    }

    func updateConfiguration(_ id: String, runtime: RuntimeKind, entrypoint: String) throws -> ProjectRecord {
        let safeEntry = try sanitize(relativePath: entrypoint)
        guard FileManager.default.fileExists(atPath: workspaceURL(id).appendingPathComponent(safeEntry).path) else {
            throw ProjectError.entrypointMissing
        }
        lock.lock(); defer { lock.unlock() }
        guard var project = projects[id] else { throw ProjectError.notFound }
        project.runtime = runtime
        project.entrypoint = safeEntry
        project.state = .stopped
        project.updatedAt = .now
        projects[id] = project
        persistLocked()
        return project
    }

    func renamePath(projectID: String, path: String, newName: String) throws {
        guard get(projectID) != nil else { throw ProjectError.notFound }
        let relative = try sanitize(relativePath: path)
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/"), !clean.contains("\0") else { throw ProjectError.invalidPath }
        let source = workspaceURL(projectID).appendingPathComponent(relative)
        let target = source.deletingLastPathComponent().appendingPathComponent(clean)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw ProjectError.invalidPath }
        try FileManager.default.moveItem(at: source, to: target)
        if let project = get(projectID), project.entrypoint == relative {
            let parent = relative.split(separator: "/").dropLast().joined(separator: "/")
            let newPath = parent.isEmpty ? clean : parent + "/" + clean
            _ = try updateConfiguration(projectID, runtime: project.runtime, entrypoint: newPath)
        } else {
            touch(projectID)
        }
        logs.append(projectID: projectID, "Renamed \(relative) to \(clean)")
    }

    func duplicatePath(projectID: String, path: String) throws -> String {
        guard get(projectID) != nil else { throw ProjectError.notFound }
        let relative = try sanitize(relativePath: path)
        let source = workspaceURL(projectID).appendingPathComponent(relative)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else { throw ProjectError.invalidPath }
        let ext = source.pathExtension
        let base = source.deletingPathExtension().lastPathComponent
        let parent = source.deletingLastPathComponent()
        var index = 1
        var target: URL
        repeat {
            let name = ext.isEmpty ? "\(base) copy \(index)" : "\(base) copy \(index).\(ext)"
            target = parent.appendingPathComponent(name, isDirectory: isDir.boolValue)
            index += 1
        } while FileManager.default.fileExists(atPath: target.path)
        try FileManager.default.copyItem(at: source, to: target)
        touch(projectID)
        let root = workspaceURL(projectID).path + "/"
        let newRelative = target.path.replacingOccurrences(of: root, with: "")
        logs.append(projectID: projectID, "Duplicated \(relative)")
        return newRelative
    }

    func movePath(projectID: String, path: String, destinationFolder: String) throws {
        guard get(projectID) != nil else { throw ProjectError.notFound }
        let relative = try sanitize(relativePath: path)
        let destination = try sanitize(relativePath: destinationFolder, allowEmpty: true)
        let source = workspaceURL(projectID).appendingPathComponent(relative)
        let folder = workspaceURL(projectID).appendingPathComponent(destination, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { throw ProjectError.invalidPath }
        let target = folder.appendingPathComponent(source.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw ProjectError.invalidPath }
        try FileManager.default.moveItem(at: source, to: target)
        touch(projectID)
        logs.append(projectID: projectID, "Moved \(relative)")
    }

    func search(projectID: String, query: String, regex: Bool = false, limit: Int = 200) throws -> [String] {
        guard get(projectID) != nil else { throw ProjectError.notFound }
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        let root = workspaceURL(projectID)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        let expression = regex ? try? NSRegularExpression(pattern: clean, options: [.caseInsensitive]) : nil
        var results: [String] = []
        for case let url as URL in enumerator {
            if results.count >= limit { break }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 1_000_000 else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if relative.localizedCaseInsensitiveContains(clean) { results.append(relative); continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let expression {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                if expression.firstMatch(in: text, range: range) != nil { results.append(relative) }
            } else if text.localizedCaseInsensitiveContains(clean) {
                results.append(relative)
            }
        }
        return results
    }

    func projectSize(_ id: String) -> Int64 {
        let root = projectURL(id)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    func workspaceURL(_ id: String) -> URL {
        projectURL(id).appendingPathComponent("workspace", isDirectory: true)
    }

    func databaseURL(_ id: String) -> URL {
        projectURL(id).appendingPathComponent("data.sqlite")
    }

    private func projectURL(_ id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    private func sanitize(relativePath: String, allowEmpty: Bool = false) throws -> String {
        var value = relativePath.removingPercentEncoding ?? relativePath
        while value.hasPrefix("/") { value.removeFirst() }
        if allowEmpty && value.isEmpty { return "" }
        guard !value.isEmpty, !value.contains("\0") else { throw ProjectError.invalidPath }

        let parts = value.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else {
            throw ProjectError.invalidPath
        }
        return parts.joined(separator: "/")
    }

    private struct State: Codable {
        let projects: [ProjectRecord]
        let deployments: [String: [DeploymentRecord]]
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateFile) else { return }
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(State.self, from: data) else { return }

        let restored = state.projects.map { project -> ProjectRecord in
            var project = project
            project.state = .stopped
            return project
        }
        projects = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) })
        deployments = state.deployments
    }

    private func persistLocked() {
        let state = State(projects: Array(projects.values), deployments: deployments)
        if let data = try? encoder.encode(state) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }
}
