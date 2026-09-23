import Foundation
import Security

final class AIProviderService: @unchecked Sendable {
    enum AIError: Error, LocalizedError {
        case missingKey, invalidBaseURL, invalidResponse, remote(Int, String)
        var errorDescription: String? {
            switch self {
            case .missingKey: return "NanoGPT API key is not configured."
            case .invalidBaseURL: return "Invalid NanoGPT base URL."
            case .invalidResponse: return "NanoGPT returned an invalid response."
            case .remote(let code, let text): return "NanoGPT error \(code): \(text)"
            }
        }
    }

    private let service = "app.pockethost.local.nanogpt"
    private let account = "api-key"
    private let defaults = UserDefaults.standard
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    var baseURL: String {
        let value = defaults.string(forKey: "ai.nanogpt.baseURL") ?? "https://nano-gpt.com/api/v1"
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    var selectedModel: String? { defaults.string(forKey: "ai.nanogpt.model") }
    var hasAPIKey: Bool { loadKey() != nil }
    var maskedAPIKey: String? {
        guard let key = loadKey() else { return nil }
        if key.count <= 8 { return "••••••••" }
        return String(key.prefix(4)) + "••••••••" + String(key.suffix(4))
    }

    func config() -> AIConfigResponse {
        .init(provider: "NanoGPT", baseURL: baseURL, apiKeyConfigured: hasAPIKey, maskedAPIKey: maskedAPIKey, selectedModel: selectedModel)
    }

    func update(_ request: AIConfigUpdateRequest) throws -> AIConfigResponse {
        if let url = request.baseURL {
            guard let parsed = URL(string: url), parsed.scheme == "https" else { throw AIError.invalidBaseURL }
            defaults.set(url.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: "ai.nanogpt.baseURL")
        }
        if let model = request.selectedModel {
            if model.isEmpty { defaults.removeObject(forKey: "ai.nanogpt.model") }
            else { defaults.set(model, forKey: "ai.nanogpt.model") }
        }
        if let key = request.apiKey {
            if key.isEmpty { deleteKey() } else { saveKey(key) }
        }
        return config()
    }

    func listModels() async throws -> [AIModel] {
        guard let url = URL(string: baseURL + "/models") else { throw AIError.invalidBaseURL }
        var request = URLRequest(url: url)
        if let key = loadKey() { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AIError.remote(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(AIModelListResponse.self, from: data).data.sorted { $0.id < $1.id }
    }

    func chat(_ input: AIChatRequest) async throws -> AIChatResponse {
        guard let key = loadKey() else { throw AIError.missingKey }
        guard let model = input.model ?? selectedModel, !model.isEmpty else { throw AIError.invalidResponse }
        guard let url = URL(string: baseURL + "/chat/completions") else { throw AIError.invalidBaseURL }
        struct Payload: Encodable { let model: String; let messages: [AIChatMessage]; let temperature: Double?; let stream = false }
        struct Choice: Decodable { let message: AIChatMessage }
        struct Raw: Decodable { let id: String?; let model: String?; let choices: [Choice] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(model: model, messages: input.messages, temperature: input.temperature))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AIError.remote(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard let message = raw.choices.first?.message else { throw AIError.invalidResponse }
        return AIChatResponse(model: raw.model ?? model, message: message, id: raw.id)
    }

    private func loadKey() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func saveKey(_ key: String) {
        deleteKey()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(item as CFDictionary, nil)
    }
    private func deleteKey() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
