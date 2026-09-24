import Foundation

struct ProjectRecord: Identifiable, Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case stopped, running, error }
    let id: String
    var name: String
    var runtime: RuntimeKind
    var entrypoint: String
    var state: State
    var activeDeploymentID: String?
    var createdAt: Date
    var updatedAt: Date
}

struct DeploymentRecord: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let projectID: String
    let createdAt: Date
    let fileCount: Int
    let totalBytes: Int
    let entrypoint: String
    let runtime: RuntimeKind
}

struct DeploymentFile: Codable, Sendable {
    let path: String
    let content: String
    let encoding: String?
}

struct CreateProjectRequest: Codable, Sendable {
    let name: String
    let runtime: String
    let entrypoint: String?
}

struct CreateDeploymentRequest: Codable, Sendable {
    let files: [DeploymentFile]
    let runtime: String?
    let entrypoint: String?
}

struct FileWriteRequest: Codable, Sendable {
    let content: String
    let encoding: String?
}

struct ProjectFileInfo: Codable, Sendable, Equatable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int
}

struct ProjectFileResponse: Codable, Sendable {
    let path: String
    let content: String
    let encoding: String
}

struct LogEntry: Codable, Sendable, Equatable {
    let id: String
    let projectID: String
    let timestamp: Date
    let level: String
    let message: String
}

struct SQLRequest: Codable, Sendable { let sql: String }
struct SQLResult: Codable, Sendable {
    let columns: [String]
    let rows: [[String: String?]]
    let changes: Int
}

struct RuntimePackManifest: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let version: String
    let runtime: String
    let sha256: String
    let signature: String
    let kind: String
}

struct RuntimePackInstallRequest: Codable, Sendable {
    let manifest: RuntimePackManifest
    let payloadBase64: String
}

struct RuntimePackStatus: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let version: String
    let runtime: String
    let kind: String
    let installedAt: Date
}

struct AIConfigResponse: Codable, Sendable {
    let providerID: String
    let provider: String
    let baseURL: String
    let apiKeyConfigured: Bool
    let maskedAPIKey: String?
    let selectedModel: String?
}

struct AIConfigUpdateRequest: Codable, Sendable {
    let apiKey: String?
    let selectedModel: String?
    let baseURL: String?
    let providerID: String?
    let providerName: String?

    init(
        apiKey: String? = nil,
        selectedModel: String? = nil,
        baseURL: String? = nil,
        providerID: String? = nil,
        providerName: String? = nil
    ) {
        self.apiKey = apiKey
        self.selectedModel = selectedModel
        self.baseURL = baseURL
        self.providerID = providerID
        self.providerName = providerName
    }
}

struct AIModel: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let ownedBy: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case ownedBy = "owned_by"
        case ownedByCamel = "ownedBy"
    }

    init(id: String, ownedBy: String?) {
        self.id = id
        self.ownedBy = ownedBy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        ownedBy = try container.decodeIfPresent(String.self, forKey: .ownedBy)
            ?? container.decodeIfPresent(String.self, forKey: .ownedByCamel)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(ownedBy, forKey: .ownedBy)
    }
}

struct AIModelListResponse: Codable, Sendable {
    let object: String?
    let data: [AIModel]
}

struct AIChatMessage: Codable, Sendable, Equatable {
    let role: String
    let content: String
}

struct AIChatRequest: Codable, Sendable {
    let model: String?
    let messages: [AIChatMessage]
    let temperature: Double?
}

struct AIChatResponse: Codable, Sendable {
    let model: String
    let message: AIChatMessage
    let id: String?
}
