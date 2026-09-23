import Foundation
import SwiftUI
import UIKit
import Security

@MainActor
final class AppModel: ObservableObject {
    // Legacy/local state kept for compatibility with existing files in the Xcode target.
    // Nexora's main project execution path is remote-first through `remote` below.
    @Published var metrics = MetricsSnapshot()
    @Published var policy = TunedPolicy(workerLimit: 2, cacheLimitMB: 64, tickIntervalMS: 500, suspendIdleRuntimes: true, note: "Controller mode")
    @Published var profile: TuneProfile = .balanced
    @Published var serverRunning = false
    @Published var serverMessage = "Local hosting disabled · controller mode"
    @Published var runtimeStatuses: [RuntimeStatus] = []
    @Published var terminalOutput = "Nexora Host terminal\nProject commands run on your configured backend."
    @Published var editorCode = "// Nexora Host edits project files remotely.\n"

    @Published var remoteProjects: [RemoteProject] = []
    @Published var remoteActivities: [RemoteTask] = []
    @Published var remoteProcesses: [RemoteProcess] = []
    @Published var backendConnected = false
    @Published var backendStatus = "Not configured"

    // Existing objects remain available so older source files continue compiling.
    let store = KeyValueStore()
    let sqlite = SQLiteStore()
    let metricsBox = MetricsBox()
    let autoTune = AutoTuneEngine()
    let apiKeyStore = APIKeyStore()
    let logs = LogBroker()
    let packs = RuntimePackManager()
    let ai = AIProviderService()

    lazy var supervisor = RuntimeSupervisor(logs: logs)
    lazy var projects = ProjectManager(logs: logs)
    lazy var projectDB = ProjectDatabaseManager(projects: projects)
    lazy var logSocket = LogWebSocketServer(logs: logs, apiKey: apiKeyStore.value)
    lazy var server = LANHTTPServer(
        store: store,
        sqlite: sqlite,
        metrics: metricsBox,
        supervisor: supervisor,
        autoTune: autoTune,
        apiKeyStore: apiKeyStore,
        projects: projects,
        logs: logs,
        projectDB: projectDB,
        packs: packs,
        ai: ai
    )

    let remote = NexoraRemoteAPI()
    var apiKey: String { apiKeyStore.value }

    private var started = false

    func start() async {
        guard !started else { return }
        started = true

        // The iPhone is a controller/editor. We intentionally do not start the old
        // local LAN host or local project runtimes here.
        runtimeStatuses = supervisor.statuses()
        await refreshRemoteOverview()
    }

    func refreshRemoteOverview() async {
        guard remote.isConfigured else {
            backendConnected = false
            backendStatus = "Add your Debian backend in Settings"
            return
        }

        do {
            let health = try await remote.health()
            backendConnected = health.ok
            backendStatus = health.ok ? "Connected · \(health.hostname ?? "backend")" : "Backend unavailable"
            async let projects = remote.listProjects()
            async let activities = remote.listTasks()
            async let processes = remote.listProcesses()
            remoteProjects = try await projects
            remoteActivities = try await activities
            remoteProcesses = try await processes
        } catch {
            backendConnected = false
            backendStatus = error.localizedDescription
        }
    }

    func setProfile(_ newValue: TuneProfile) async {
        profile = newValue
    }

    func toggleServer() async {
        // Kept only for source compatibility. Nexora no longer turns the iPhone
        // into the project host.
        serverRunning = false
        serverMessage = "Project hosting runs on your Debian backend"
    }

    func runEditor(kind: RuntimeKind = .javascript) async -> RuntimeResult {
        .init(output: "Open a Nexora Host project and run it on the remote backend.", succeeded: false)
    }

    func runCommand(_ raw: String) async {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        terminalOutput += "\n$ \(command)\nOpen a project → Terminal to run this command remotely."
    }
}

// MARK: - Remote API models

struct RemoteHealth: Codable, Sendable {
    let ok: Bool
    let hostname: String?
    let version: String?
    let uptimeSeconds: Double?
}

struct RemoteProject: Codable, Identifiable, Sendable, Hashable {
    let id: String
    var name: String
    var repoURL: String?
    var branch: String
    var runtime: String
    var framework: String?
    var packageManager: String?
    var status: String
    var startCommand: String?
    var entrypoint: String?
    var port: Int?
    var previewURL: String?
    var latestCommit: String?
    var createdAt: Date
    var updatedAt: Date
}

struct RemoteFileInfo: Codable, Identifiable, Sendable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int
    let modifiedAt: Date?
}

struct RemoteFileContent: Codable, Sendable {
    let path: String
    let content: String
    let encoding: String
}

struct RemoteTask: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let projectID: String?
    let kind: String
    let status: String
    let command: String?
    let output: String
    let exitCode: Int?
    let currentStep: String?
    let startedAt: Date
    let finishedAt: Date?
}

struct RemoteProcess: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let projectID: String
    let projectName: String
    let pid: Int?
    let command: String
    let status: String
    let port: Int?
    let uptimeSeconds: Double
    let cpuPercent: Double?
    let memoryMB: Double?
    let previewURL: String?
}

struct RemoteLogLine: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let timestamp: Date
    let level: String
    let message: String
}

struct RemoteOK: Codable, Sendable { let ok: Bool }


struct RemoteRuntimeInfo: Codable, Identifiable, Sendable, Hashable {
    var id: String { name }
    let name: String
    let installed: Bool
    let version: String?
    let command: String
}

struct RemoteGitStatus: Codable, Sendable {
    let branch: String
    let clean: Bool
    let changed: [String]
    let ahead: Int?
    let behind: Int?
    let latestCommit: String?
}

struct RemoteCommandRequest: Encodable {
    let command: String
    let confirmed: Bool
}

struct RemoteCloneRequest: Encodable {
    let url: String
    let branch: String?
    let name: String?
}

struct RemoteCreateRequest: Encodable {
    let name: String
    let template: String
}

struct RemoteWriteFileRequest: Encodable {
    let content: String
    let encoding: String
}

struct RemoteCreateFolderRequest: Encodable {
    let path: String
}

struct RemoteGitCommitRequest: Encodable {
    let message: String
    let push: Bool
}

// MARK: - Remote API client

final class NexoraRemoteAPI: @unchecked Sendable {
    enum RemoteError: Error, LocalizedError {
        case notConfigured
        case invalidURL
        case invalidResponse
        case unauthorized
        case remote(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Configure Backend URL and Owner Token in Settings."
            case .invalidURL: return "The backend URL is invalid."
            case .invalidResponse: return "The backend returned an unreadable response."
            case .unauthorized: return "Owner authentication failed. Check your token."
            case .remote(let status, let message):
                return message.isEmpty ? "Backend request failed (HTTP \(status))." : message
            }
        }
    }

    private let defaults = UserDefaults.standard
    private let session: URLSession
    private let keychainService = "app.nexora.dev.backend"
    private let keychainAccount = "owner-token"

    init(session: URLSession = .shared) {
        self.session = session
    }

    var baseURL: String {
        (defaults.string(forKey: "nexora.backend.url") ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var isConfigured: Bool {
        !baseURL.isEmpty && ownerToken != nil
    }

    var maskedToken: String? {
        guard let token = ownerToken else { return nil }
        guard token.count > 8 else { return "••••••••" }
        return String(token.prefix(4)) + "••••••••" + String(token.suffix(4))
    }

    func configure(baseURL: String, ownerToken: String?) throws {
        let clean = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: clean), url.scheme == "https" || url.scheme == "http" else {
            throw RemoteError.invalidURL
        }
        defaults.set(clean, forKey: "nexora.backend.url")
        if let ownerToken {
            let trimmed = ownerToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { saveToken(trimmed) }
        }
    }

    func clearToken() {
        deleteToken()
    }

    func health() async throws -> RemoteHealth {
        try await request("/api/v1/health", auth: false)
    }

    func listProjects() async throws -> [RemoteProject] {
        try await request("/api/v1/projects")
    }

    func cloneProject(url: String, branch: String?, name: String?) async throws -> RemoteProject {
        try await request(
            "/api/v1/projects/clone",
            method: "POST",
            body: RemoteCloneRequest(url: url, branch: branch, name: name)
        )
    }

    func createProject(name: String, template: String) async throws -> RemoteProject {
        try await request(
            "/api/v1/projects/create",
            method: "POST",
            body: RemoteCreateRequest(name: name, template: template)
        )
    }

    func project(_ id: String) async throws -> RemoteProject {
        try await request("/api/v1/projects/\(escape(id))")
    }

    func listFiles(projectID: String, path: String = "") async throws -> [RemoteFileInfo] {
        let query = path.isEmpty ? "" : "?path=\(queryValue(path))"
        return try await request("/api/v1/projects/\(escape(projectID))/files\(query)")
    }

    func readFile(projectID: String, path: String) async throws -> RemoteFileContent {
        try await request("/api/v1/projects/\(escape(projectID))/file?path=\(queryValue(path))")
    }

    func writeFile(projectID: String, path: String, content: String) async throws -> RemoteFileContent {
        try await request(
            "/api/v1/projects/\(escape(projectID))/file?path=\(queryValue(path))",
            method: "PUT",
            body: RemoteWriteFileRequest(content: content, encoding: "utf8")
        )
    }

    func createFolder(projectID: String, path: String) async throws {
        let _: RemoteOK = try await request(
            "/api/v1/projects/\(escape(projectID))/folder",
            method: "POST",
            body: RemoteCreateFolderRequest(path: path)
        )
    }

    func deletePath(projectID: String, path: String) async throws {
        let _: RemoteOK = try await request(
            "/api/v1/projects/\(escape(projectID))/file?path=\(queryValue(path))",
            method: "DELETE"
        )
    }

    func runCommand(projectID: String, command: String, confirmed: Bool = false) async throws -> RemoteTask {
        try await request(
            "/api/v1/projects/\(escape(projectID))/commands",
            method: "POST",
            body: RemoteCommandRequest(command: command, confirmed: confirmed)
        )
    }

    func setupProject(projectID: String) async throws -> RemoteTask {
        try await request("/api/v1/projects/\(escape(projectID))/setup", method: "POST")
    }

    func startProject(projectID: String) async throws -> RemoteTask {
        try await request("/api/v1/projects/\(escape(projectID))/start", method: "POST")
    }

    func stopProject(projectID: String) async throws -> RemoteOK {
        try await request("/api/v1/projects/\(escape(projectID))/stop", method: "POST")
    }

    func restartProject(projectID: String) async throws -> RemoteTask {
        try await request("/api/v1/projects/\(escape(projectID))/restart", method: "POST")
    }

    func task(_ id: String) async throws -> RemoteTask {
        try await request("/api/v1/tasks/\(escape(id))")
    }

    func cancelTask(_ id: String) async throws -> RemoteOK {
        try await request("/api/v1/tasks/\(escape(id))/cancel", method: "POST")
    }

    func listTasks() async throws -> [RemoteTask] {
        try await request("/api/v1/tasks")
    }

    func listProcesses() async throws -> [RemoteProcess] {
        try await request("/api/v1/processes")
    }

    func listRuntimes() async throws -> [RemoteRuntimeInfo] {
        try await request("/api/v1/runtimes")
    }

    func logs(projectID: String, limit: Int = 250) async throws -> [RemoteLogLine] {
        try await request("/api/v1/projects/\(escape(projectID))/logs?limit=\(limit)")
    }

    func gitStatus(projectID: String) async throws -> RemoteGitStatus {
        try await request("/api/v1/projects/\(escape(projectID))/git/status")
    }

    func gitPull(projectID: String) async throws -> RemoteTask {
        try await request("/api/v1/projects/\(escape(projectID))/git/pull", method: "POST")
    }

    func gitCommit(projectID: String, message: String, push: Bool) async throws -> RemoteTask {
        try await request(
            "/api/v1/projects/\(escape(projectID))/git/commit",
            method: "POST",
            body: RemoteGitCommitRequest(message: message, push: push)
        )
    }

    private var ownerToken: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveToken(_ token: String) {
        deleteToken()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    private func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        auth: Bool = true
    ) async throws -> T {
        try await request(path, method: method, bodyData: nil, auth: auth)
    }

    private func request<T: Decodable, B: Encodable>(
        _ path: String,
        method: String,
        body: B,
        auth: Bool = true
    ) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await request(path, method: method, bodyData: data, auth: auth)
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String,
        bodyData: Data?,
        auth: Bool
    ) async throws -> T {
        guard !baseURL.isEmpty else { throw RemoteError.notConfigured }
        guard let url = URL(string: baseURL + path) else { throw RemoteError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bodyData {
            req.httpBody = bodyData
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if auth {
            guard let token = ownerToken else { throw RemoteError.notConfigured }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RemoteError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw RemoteError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                ?? String(data: data, encoding: .utf8)
                ?? ""
            throw RemoteError.remote(http.statusCode, message)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(T.self, from: data) }
        catch { throw RemoteError.invalidResponse }
    }

    private func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func queryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

