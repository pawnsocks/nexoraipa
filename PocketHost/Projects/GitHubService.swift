import Foundation
import Security
import CryptoKit

struct GitHubRepository: Identifiable, Codable, Sendable, Hashable {
    let id: Int
    let name: String
    let fullName: String
    let privateRepo: Bool
    let defaultBranch: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case fullName = "full_name"
        case privateRepo = "private"
        case defaultBranch = "default_branch"
        case htmlURL = "html_url"
    }
}

struct GitHubProjectLink: Codable, Sendable, Equatable {
    let owner: String
    let repo: String
    var branch: String
    var headSHA: String
    var treeSHA: String
    var baselineHashes: [String: String]
}

struct GitHubFileChange: Identifiable, Sendable, Equatable {
    enum Status: String, Sendable { case added, modified, deleted }
    var id: String { path }
    let path: String
    let status: Status
}

final class GitHubService: @unchecked Sendable {
    enum GitHubError: Error, LocalizedError {
        case invalidRepository
        case missingToken
        case invalidResponse
        case remote(Int, String)
        case tooLarge
        case conflict
        case noLink

        var errorDescription: String? {
            switch self {
            case .invalidRepository: return "GitHub repository URL is invalid."
            case .missingToken: return "A GitHub token is required for this repository."
            case .invalidResponse: return "GitHub returned an unreadable response."
            case .remote(let code, let message): return message.isEmpty ? "GitHub request failed with HTTP \(code)." : "GitHub request failed with HTTP \(code): \(message)"
            case .tooLarge: return "Repository is too large for the current mobile import limit."
            case .conflict: return "The remote branch changed since the last import/push. Pull before pushing."
            case .noLink: return "This project is not linked to a GitHub repository."
            }
        }
    }

    private let session: URLSession
    private let service = "app.nexorahost.github"
    private let account = "token"

    init(session: URLSession = .shared) { self.session = session }

    var hasToken: Bool { token != nil }
    var maskedToken: String? {
        guard let token else { return nil }
        guard token.count > 8 else { return "••••••••" }
        return String(token.prefix(4)) + "••••••••" + String(token.suffix(4))
    }

    func saveToken(_ value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { deleteToken(); return }
        deleteToken()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(clean.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    func repositories() async throws -> [GitHubRepository] {
        guard token != nil else { throw GitHubError.missingToken }
        return try await request("https://api.github.com/user/repos?sort=updated&per_page=100")
    }

    func searchRepositories(_ query: String) async throws -> [GitHubRepository] {
        struct SearchResult: Decodable { let items: [GitHubRepository] }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let result: SearchResult = try await request("https://api.github.com/search/repositories?q=\(encoded)&per_page=50")
        return result.items
    }

    func importRepository(
        repositoryURL: String,
        branch requestedBranch: String? = nil,
        projectName: String? = nil,
        projects: ProjectManager,
        history: HistoryStore
    ) async throws -> ProjectRecord {
        let pair = try parseRepositoryURL(repositoryURL)
        let repo: GitHubRepository = try await request("https://api.github.com/repos/\(pair.owner)/\(pair.repo)")
        let branch = requestedBranch?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? repo.defaultBranch
        let ref: RefResponse = try await request("https://api.github.com/repos/\(pair.owner)/\(pair.repo)/git/ref/heads/\(encodePath(branch))")
        let commit: CommitResponse = try await request("https://api.github.com/repos/\(pair.owner)/\(pair.repo)/git/commits/\(ref.object.sha)")
        let tree: TreeResponse = try await request("https://api.github.com/repos/\(pair.owner)/\(pair.repo)/git/trees/\(commit.tree.sha)?recursive=1")
        if tree.truncated == true { throw GitHubError.tooLarge }

        let blobs = tree.tree.filter { $0.type == "blob" && !$0.path.hasPrefix(".git/") }
        guard blobs.count <= 1_000 else { throw GitHubError.tooLarge }
        let declaredBytes = blobs.reduce(0) { $0 + ($1.size ?? 0) }
        guard declaredBytes <= 50 * 1024 * 1024 else { throw GitHubError.tooLarge }

        let initialRuntime = detectRuntime(paths: blobs.map(\.path)).runtime
        let project = try projects.create(name: projectName?.nonEmpty ?? repo.name, runtime: initialRuntime, entrypoint: nil)

        var hashes: [String: String] = [:]
        var totalBytes = 0
        do {
            for item in blobs {
                guard let sha = item.sha else { continue }
                let blob: BlobResponse = try await request("https://api.github.com/repos/\(pair.owner)/\(pair.repo)/git/blobs/\(sha)")
                guard blob.encoding == "base64", let data = Data(base64Encoded: blob.content.replacingOccurrences(of: "\n", with: "")) else { continue }
                totalBytes += data.count
                guard totalBytes <= 50 * 1024 * 1024 else { throw GitHubError.tooLarge }
                let content: String
                let encoding: String
                if let text = String(data: data, encoding: .utf8) {
                    content = text
                    encoding = "utf8"
                } else {
                    content = data.base64EncodedString()
                    encoding = "base64"
                }
                _ = try projects.writeFile(projectID: project.id, path: item.path, request: .init(content: content, encoding: encoding))
                hashes[item.path] = sha256(data)
            }

            let detection = detectRuntime(paths: blobs.map(\.path))
            let updated = try projects.updateConfiguration(project.id, runtime: detection.runtime, entrypoint: detection.entrypoint)
            let link = GitHubProjectLink(owner: pair.owner, repo: pair.repo, branch: branch, headSHA: ref.object.sha, treeSHA: commit.tree.sha, baselineHashes: hashes)
            try saveLink(link, projectID: project.id, projects: projects)
            history.append(projectID: project.id, kind: .gitImport, title: "GitHub repository imported", detail: "\(pair.owner)/\(pair.repo) · \(branch)")
            return updated
        } catch {
            try? projects.delete(project.id)
            throw error
        }
    }

    func link(projectID: String, projects: ProjectManager) -> GitHubProjectLink? {
        let url = linkURL(projectID: projectID, projects: projects)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GitHubProjectLink.self, from: data)
    }

    func changes(projectID: String, projects: ProjectManager) throws -> [GitHubFileChange] {
        guard let link = link(projectID: projectID, projects: projects) else { throw GitHubError.noLink }
        let current = try currentFiles(projectID: projectID, projects: projects)
        var out: [GitHubFileChange] = []
        for (path, data) in current {
            let hash = sha256(data)
            if let old = link.baselineHashes[path] {
                if old != hash { out.append(.init(path: path, status: .modified)) }
            } else {
                out.append(.init(path: path, status: .added))
            }
        }
        for path in link.baselineHashes.keys where current[path] == nil {
            out.append(.init(path: path, status: .deleted))
        }
        return out.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    func push(projectID: String, message: String, projects: ProjectManager, history: HistoryStore) async throws -> GitHubProjectLink {
        guard var link = link(projectID: projectID, projects: projects) else { throw GitHubError.noLink }
        let latestRef: RefResponse = try await request("https://api.github.com/repos/\(link.owner)/\(link.repo)/git/ref/heads/\(encodePath(link.branch))")
        guard latestRef.object.sha == link.headSHA else { throw GitHubError.conflict }

        let current = try currentFiles(projectID: projectID, projects: projects)
        var entries: [[String: Any]] = []
        var hashes: [String: String] = [:]

        for (path, data) in current {
            let blobPayload: [String: Any] = ["content": data.base64EncodedString(), "encoding": "base64"]
            let blobData = try JSONSerialization.data(withJSONObject: blobPayload)
            let blob: CreatedBlob = try await request("https://api.github.com/repos/\(link.owner)/\(link.repo)/git/blobs", method: "POST", bodyData: blobData)
            entries.append(["path": path, "mode": "100644", "type": "blob", "sha": blob.sha])
            hashes[path] = sha256(data)
        }

        for oldPath in link.baselineHashes.keys where current[oldPath] == nil {
            entries.append(["path": oldPath, "mode": "100644", "type": "blob", "sha": NSNull()])
        }

        let treePayload: [String: Any] = ["base_tree": link.treeSHA, "tree": entries]
        let treeData = try JSONSerialization.data(withJSONObject: treePayload)
        let newTree: CreatedTree = try await request("https://api.github.com/repos/\(link.owner)/\(link.repo)/git/trees", method: "POST", bodyData: treeData)

        let commitPayload: [String: Any] = ["message": message.nonEmpty ?? "Update from Nexora Host", "tree": newTree.sha, "parents": [link.headSHA]]
        let commitData = try JSONSerialization.data(withJSONObject: commitPayload)
        let newCommit: CreatedCommit = try await request("https://api.github.com/repos/\(link.owner)/\(link.repo)/git/commits", method: "POST", bodyData: commitData)

        let refData = try JSONSerialization.data(withJSONObject: ["sha": newCommit.sha, "force": false])
        let _: RefResponse = try await request("https://api.github.com/repos/\(link.owner)/\(link.repo)/git/refs/heads/\(encodePath(link.branch))", method: "PATCH", bodyData: refData)

        link.headSHA = newCommit.sha
        link.treeSHA = newTree.sha
        link.baselineHashes = hashes
        try saveLink(link, projectID: projectID, projects: projects)
        history.append(projectID: projectID, kind: .gitCommit, title: "Pushed to GitHub", detail: message)
        return link
    }

    private func currentFiles(projectID: String, projects: ProjectManager) throws -> [String: Data] {
        let root = projects.workspaceURL(projectID)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [:] }
        var output: [String: Data] = [:]
        var total = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if relative.hasPrefix(".nexora/") || relative == ".nexora" { continue }
            let data = try Data(contentsOf: url)
            total += data.count
            guard total <= 50 * 1024 * 1024 else { throw GitHubError.tooLarge }
            output[relative] = data
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
        if set.contains("package.json") { return (.javascript, set.contains("src/index.js") ? "src/index.js" : "index.js") }
        if let py = paths.first(where: { $0.hasSuffix(".py") }) { return (.python, py) }
        if let lua = paths.first(where: { $0.hasSuffix(".lua") }) { return (.lua, lua) }
        if let js = paths.first(where: { $0.hasSuffix(".js") }) { return (.javascript, js) }
        return (.javascript, "index.js")
    }

    private func saveLink(_ link: GitHubProjectLink, projectID: String, projects: ProjectManager) throws {
        let url = linkURL(projectID: projectID, projects: projects)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(link)
        try data.write(to: url, options: .atomic)
    }

    private func linkURL(projectID: String, projects: ProjectManager) -> URL {
        projects.workspaceURL(projectID).appendingPathComponent(".nexora", isDirectory: true).appendingPathComponent("github.json")
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func parseRepositoryURL(_ value: String) throws -> (owner: String, repo: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.contains("/") && !clean.contains("://") {
            let parts = clean.split(separator: "/").map(String.init)
            guard parts.count == 2 else { throw GitHubError.invalidRepository }
            return (parts[0], parts[1].replacingOccurrences(of: ".git", with: ""))
        }
        guard let url = URL(string: clean), url.host?.lowercased().contains("github.com") == true else { throw GitHubError.invalidRepository }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { throw GitHubError.invalidRepository }
        return (parts[0], parts[1].replacingOccurrences(of: ".git", with: ""))
    }

    private var token: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func request<T: Decodable>(_ urlString: String, method: String = "GET", bodyData: Data? = nil) async throws -> T {
        guard let url = URL(string: urlString) else { throw GitHubError.invalidRepository }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Nexora-Host", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 401 || http.statusCode == 403, token == nil { throw GitHubError.missingToken }
            throw GitHubError.remote(http.statusCode, message)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw GitHubError.invalidResponse }
    }

    private func encodePath(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private struct RefResponse: Decodable {
        struct Object: Decodable { let sha: String }
        let object: Object
    }

    private struct CommitResponse: Decodable {
        struct Tree: Decodable { let sha: String }
        let tree: Tree
    }

    private struct TreeResponse: Decodable {
        struct Item: Decodable { let path: String; let type: String; let sha: String?; let size: Int? }
        let tree: [Item]
        let truncated: Bool?
    }

    private struct BlobResponse: Decodable { let content: String; let encoding: String }
    private struct CreatedBlob: Decodable { let sha: String }
    private struct CreatedTree: Decodable { let sha: String }
    private struct CreatedCommit: Decodable { let sha: String }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
