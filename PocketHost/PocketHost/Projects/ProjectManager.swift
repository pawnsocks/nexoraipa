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
            .appendingPathComponent("PocketHost", isDirectory: true)
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
        return projects.values.sorted { $0.createdAt < $1.createdAt }
    }

    func get(_ id: String) -> ProjectRecord? {
        lock.lock(); defer { lock.unlock() }
        return projects[id]
    }

    func create(name: String, runtime: RuntimeKind, entrypoint: String?) throws -> ProjectRecord {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty && clean.count <= 80 else { throw ProjectError.invalidName }
        let id = UUID().uuidString.lowercased()
        let defaultEntry: String
        switch runtime { case .javascript: defaultEntry = "index.js"; case .python: defaultEntry = "main.py"; case .lua: defaultEntry = "main.lua" }
        let entry = try sanitize(relativePath: entrypoint ?? defaultEntry)
        let now = Date()
        let record = ProjectRecord(id: id, name: clean, runtime: runtime, entrypoint: entry, state: .stopped, activeDeploymentID: nil, createdAt: now, updatedAt: now)
        try FileManager.default.createDirectory(at: workspaceURL(id), withIntermediateDirectories: true)
        lock.lock(); projects[id] = record; persistLocked(); lock.unlock()
        logs.append(projectID: id, "Project created")
        return record
    }

    func delete(_ id: String) throws {
        lock.lock()
        guard projects.removeValue(forKey: id) != nil else { lock.unlock(); throw ProjectError.notFound }
        deployments[id] = nil
        persistLocked(); lock.unlock()
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

    func deploy(projectID: String, request: CreateDeploymentRequest) throws -> DeploymentRecord {
        guard var project = get(projectID) else { throw ProjectError.notFound }
        if let raw = request.runtime {
            guard let runtime = RuntimeKind.apiValue(raw) else { throw ProjectError.invalidRuntime }
            project.runtime = runtime
        }
        if let entry = request.entrypoint { project.entrypoint = try sanitize(relativePath: entry) }
        let deploymentID = UUID().uuidString.lowercased()
        let release = projectURL(projectID).appendingPathComponent("releases", isDirectory: true).appendingPathComponent(deploymentID, isDirectory: true)
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        var total = 0
        for file in request.files {
            let relative = try sanitize(relativePath: file.path)
            let data: Data
            switch (file.encoding ?? "utf8").lowercased() {
            case "utf8", "text": data = Data(file.content.utf8)
            case "base64": guard let decoded = Data(base64Encoded: file.content) else { throw ProjectError.invalidPath }; data = decoded
            default: throw ProjectError.invalidPath
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
        let record = DeploymentRecord(id: deploymentID, projectID: projectID, createdAt: .now, fileCount: request.files.count, totalBytes: total, entrypoint: project.entrypoint, runtime: project.runtime)
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
        guard let data = FileManager.default.contents(atPath: url.path), let source = String(data: data, encoding: .utf8) else { throw ProjectError.entrypointMissing }
        return (project, source)
    }

    func listFiles(projectID: String, path: String = "") throws -> [ProjectFileInfo] {
        guard get(projectID) != nil else { throw ProjectError.notFound }
        let relative = try sanitize(relativePath: path, allowEmpty: true)
        let dir = workspaceURL(projectID).appendingPathComponent(relative)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { throw ProjectError.invalidPath }
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]).map { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let rel = url.path.replacingOccurrences(of: workspaceURL(projectID).path + "/", with: "")
            return ProjectFileInfo(path: rel, name: url.lastPathComponent, isDirectory: values.isDirectory ?? false, size: values.fileSize ?? 0)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func readFile(projectID: String, path: String) throws -> ProjectFileResponse {
        guard get(projectID) != nil else { throw ProjectError.notFound }
        let relative = try sanitize(relativePath: path)
        let data = try Data(contentsOf: workspaceURL(projectID).appendingPathComponent(relative))
        if let text = String(data: data, encoding: .utf8) { return .init(path: relative, content: text, encoding: "utf8") }
        return .init(path: relative, content: data.base64EncodedString(), encoding: "base64")
    }

    func writeFile(projectID: String, path: String, request: FileWriteRequest) throws -> ProjectFileResponse {
        guard get(projectID) != nil else { throw ProjectError.notFound }
        let relative = try sanitize(relativePath: path)
        let data: Data
        switch (request.encoding ?? "utf8").lowercased() {
        case "utf8", "text": data = Data(request.content.utf8)
        case "base64": guard let decoded = Data(base64Encoded: request.content) else { throw ProjectError.invalidPath }; data = decoded
        default: throw ProjectError.invalidPath
        }
        guard data.count <= 5 * 1024 * 1024 else { throw ProjectError.invalidPath }
        let target = workspaceURL(projectID).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        logs.append(projectID: projectID, "Updated file \(relative)")
        return try readFile(projectID: projectID, path: relative)
    }

    func deleteFile(projectID: String, path: String) throws {
        guard get(projectID) != nil else { throw ProjectError.notFound }
        let relative = try sanitize(relativePath: path)
        try FileManager.default.removeItem(at: workspaceURL(projectID).appendingPathComponent(relative))
        logs.append(projectID: projectID, "Deleted file \(relative)")
    }

    func workspaceURL(_ id: String) -> URL { projectURL(id).appendingPathComponent("workspace", isDirectory: true) }
    func databaseURL(_ id: String) -> URL { projectURL(id).appendingPathComponent("data.sqlite") }

    private func projectURL(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    private func sanitize(relativePath: String, allowEmpty: Bool = false) throws -> String {
        var value = relativePath.removingPercentEncoding ?? relativePath
        while value.hasPrefix("/") { value.removeFirst() }
        if allowEmpty && value.isEmpty { return "" }
        guard !value.isEmpty, !value.contains("\0") else { throw ProjectError.invalidPath }
        let parts = value.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { throw ProjectError.invalidPath }
        return parts.joined(separator: "/")
    }

    private struct State: Codable { let projects: [ProjectRecord]; let deployments: [String: [DeploymentRecord]] }
    private func load() {
        guard let data = try? Data(contentsOf: stateFile) else { return }
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(State.self, from: data) else { return }
        // Runtime contexts are in-process and never survive an iOS app relaunch.
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
        if let data = try? encoder.encode(state) { try? data.write(to: stateFile, options: .atomic) }
    }
}
