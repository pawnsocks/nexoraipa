import Foundation
import Security

final class AIProviderService: @unchecked Sendable {
    enum AIError: Error, LocalizedError {
        case missingKey
        case invalidBaseURL
        case invalidResponse
        case insufficientBalance(available: Double?, required: Double?, subscriptionCovered: Bool?, freeCovered: Bool?)
        case remote(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "Add your NanoGPT API key in Settings first."
            case .invalidBaseURL:
                return "The NanoGPT API URL is invalid."
            case .invalidResponse:
                return "NanoGPT returned a response Nexora Host could not read."
            case .insufficientBalance(let available, let required, let subscriptionCovered, let freeCovered):
                var parts: [String] = ["This request is not covered by your current NanoGPT access."]
                if subscriptionCovered == true {
                    parts = ["NanoGPT says the base model is covered by your subscription, but the request still needs extra balance."]
                } else if freeCovered == true {
                    parts = ["NanoGPT says the base model has free access, but this request still needs extra balance."]
                }
                if let available, let required {
                    parts.append(String(format: "Balance: $%.4f · required: $%.4f.", available, required))
                }
                parts.append("Choose another model or add NanoGPT balance.")
                return parts.joined(separator: " ")
            case .remote(let code, let text):
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.isEmpty ? "NanoGPT request failed (HTTP \(code))." : "NanoGPT request failed (HTTP \(code)): \(clean)"
            }
        }
    }

    private let service = "app.nexorahost.local.nanogpt"
    private let account = "api-key"
    private let defaults = UserDefaults.standard
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    var baseURL: String {
        let value = defaults.string(forKey: "ai.nanogpt.baseURL") ?? "https://nano-gpt.com/api/v1"
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var selectedModel: String? {
        defaults.string(forKey: "ai.nanogpt.model")
    }

    var hasAPIKey: Bool { loadKey() != nil }

    var maskedAPIKey: String? {
        guard let key = loadKey() else { return nil }
        if key.count <= 8 { return "••••••••" }
        return String(key.prefix(4)) + "••••••••" + String(key.suffix(4))
    }

    func config() -> AIConfigResponse {
        .init(
            provider: "NanoGPT",
            baseURL: baseURL,
            apiKeyConfigured: hasAPIKey,
            maskedAPIKey: maskedAPIKey,
            selectedModel: selectedModel
        )
    }

    func update(_ request: AIConfigUpdateRequest) throws -> AIConfigResponse {
        if let url = request.baseURL {
            guard let parsed = URL(string: url), parsed.scheme == "https" else {
                throw AIError.invalidBaseURL
            }
            defaults.set(url.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: "ai.nanogpt.baseURL")
        }

        if let model = request.selectedModel {
            if model.isEmpty {
                defaults.removeObject(forKey: "ai.nanogpt.model")
            } else {
                defaults.set(model, forKey: "ai.nanogpt.model")
            }
        }

        if let key = request.apiKey {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                deleteKey()
            } else {
                saveKey(trimmed)
            }
        }

        return config()
    }

    func listModels() async throws -> [AIModel] {
        guard let url = URL(string: baseURL + "/models") else { throw AIError.invalidBaseURL }
        var request = URLRequest(url: url)
        if let key = loadKey() {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw parseRemoteError(status: http.statusCode, data: data)
        }

        return try JSONDecoder()
            .decode(AIModelListResponse.self, from: data)
            .data
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    func chat(_ input: AIChatRequest) async throws -> AIChatResponse {
        guard let key = loadKey() else { throw AIError.missingKey }
        guard let model = input.model ?? selectedModel, !model.isEmpty else { throw AIError.invalidResponse }
        guard let url = URL(string: baseURL + "/chat/completions") else { throw AIError.invalidBaseURL }

        struct Payload: Encodable {
            let model: String
            let messages: [AIChatMessage]
            let temperature: Double?
            let stream = false
        }
        struct Choice: Decodable { let message: AIChatMessage }
        struct Raw: Decodable {
            let id: String?
            let model: String?
            let choices: [Choice]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Payload(model: model, messages: input.messages, temperature: input.temperature)
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw parseRemoteError(status: http.statusCode, data: data)
        }

        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard let message = raw.choices.first?.message else { throw AIError.invalidResponse }
        return AIChatResponse(model: raw.model ?? model, message: message, id: raw.id)
    }

    private func parseRemoteError(status: Int, data: Data) -> Error {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return AIError.remote(status, String(data: data, encoding: .utf8) ?? "")
        }

        let nested = json["error"] as? [String: Any]
        let source = nested ?? json
        let code = (source["code"] as? String) ?? (json["code"] as? String)

        if status == 402 || code == "insufficient_balance" {
            let available = number(source["availableBalance"])
                ?? number(source["available_balance"])
                ?? number(source["available"])
            let required = number(source["requiredBalance"])
                ?? number(source["required_balance"])
                ?? number(source["required"])
            let subscription = bool(source["baseModelCoveredBySubscription"])
                ?? bool(source["base_model_covered_by_subscription"])
            let free = bool(source["baseModelCoveredByFreeAccess"])
                ?? bool(source["base_model_covered_by_free_access"])
            return AIError.insufficientBalance(
                available: available,
                required: required,
                subscriptionCovered: subscription,
                freeCovered: free
            )
        }

        let message = (source["message"] as? String)
            ?? (json["message"] as? String)
            ?? String(data: data, encoding: .utf8)
            ?? ""
        return AIError.remote(status, message)
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            if value.lowercased() == "true" { return true }
            if value.lowercased() == "false" { return false }
        }
        return nil
    }

    private func loadKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func saveKey(_ key: String) {
        deleteKey()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    private func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
