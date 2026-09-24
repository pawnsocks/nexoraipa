import Foundation
import Security

enum AIProviderProtocolKind: String, Codable, Sendable {
    case openAICompatible
    case anthropic
    case gemini
    case cohere
}

struct AIProviderDefinition: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let name: String
    let baseURL: String
    let kind: AIProviderProtocolKind
    let supportsModelDiscovery: Bool

    static let presets: [AIProviderDefinition] = [
        .init(id: "freepool", name: "Free AI Pool", baseURL: "", kind: .openAICompatible, supportsModelDiscovery: true),
        .init(id: "nanogpt", name: "NanoGPT", baseURL: "https://nano-gpt.com/api/v1", kind: .openAICompatible, supportsModelDiscovery: true),
        .init(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", kind: .openAICompatible, supportsModelDiscovery: true),
        .init(id: "anthropic", name: "Anthropic", baseURL: "https://api.anthropic.com/v1", kind: .anthropic, supportsModelDiscovery: true),
        .init(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta", kind: .gemini, supportsModelDiscovery: true),
        .init(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", kind: .openAICompatible, supportsModelDiscovery: true),
        .init(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", kind: .openAICompatible, supportsModelDiscovery: true),
        .init(id: "mistral", name: "Mistral", baseURL: "https://api.mistral.ai/v1", kind: .openAICompatible, supportsModelDiscovery: true),
        .init(id: "xai", name: "xAI", baseURL: "https://api.x.ai/v1", kind: .openAICompatible, supportsModelDiscovery: true),
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", kind: .openAICompatible, supportsModelDiscovery: true),
        .init(id: "together", name: "Together AI", baseURL: "https://api.together.xyz/v1", kind: .openAICompatible, supportsModelDiscovery: true),
        .init(id: "fireworks", name: "Fireworks AI", baseURL: "https://api.fireworks.ai/inference/v1", kind: .openAICompatible, supportsModelDiscovery: true),
        .init(id: "cerebras", name: "Cerebras", baseURL: "https://api.cerebras.ai/v1", kind: .openAICompatible, supportsModelDiscovery: true),
        .init(id: "cohere", name: "Cohere", baseURL: "https://api.cohere.com", kind: .cohere, supportsModelDiscovery: true),
        .init(id: "custom", name: "Custom OpenAI-Compatible", baseURL: "", kind: .openAICompatible, supportsModelDiscovery: true)
    ]
}

final class AIProviderService: @unchecked Sendable {
    enum AIError: Error, LocalizedError {
        case missingKey
        case invalidBaseURL
        case invalidResponse
        case missingModel
        case insufficientBalance(available: Double?, required: Double?, subscriptionCovered: Bool?, freeCovered: Bool?)
        case remote(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "Add an API key for the selected AI provider first."
            case .invalidBaseURL:
                return "The AI provider base URL is invalid."
            case .invalidResponse:
                return "The AI provider returned a response Nexora Host could not read."
            case .missingModel:
                return "Choose a model first."
            case .insufficientBalance(let available, let required, let subscriptionCovered, let freeCovered):
                var parts: [String] = ["This request is not covered by the current provider access."]
                if subscriptionCovered == true {
                    parts = ["The provider says the base model is subscription-covered, but this request still needs extra balance."]
                } else if freeCovered == true {
                    parts = ["The provider says the base model has free access, but this request still needs extra balance."]
                }
                if let available, let required { parts.append(String(format: "Balance: $%.4f · required: $%.4f.", available, required)) }
                parts.append("Choose another model or update provider billing/access.")
                return parts.joined(separator: " ")
            case .remote(let code, let text):
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.isEmpty ? "AI request failed (HTTP \(code))." : "AI request failed (HTTP \(code)): \(clean)"
            }
        }
    }

    private let service = "app.nexorahost.ai"
    private let defaults = UserDefaults.standard
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        let stored = defaults.string(forKey: "ai.provider.id")
        if stored == nil {
            defaults.set(loadKey(providerID: "nanogpt") != nil ? "nanogpt" : "freepool", forKey: "ai.provider.id")
        } else if stored == "freepool", loadKey(providerID: "nanogpt") != nil {
            // Upgrade behavior: an already-saved NanoGPT key takes priority.
            defaults.set("nanogpt", forKey: "ai.provider.id")
        }
    }

    var providers: [AIProviderDefinition] { AIProviderDefinition.presets }

    var nanoGPTConfigured: Bool { loadKey(providerID: "nanogpt") != nil }

    var selectedProviderID: String {
        // NanoGPT is an explicit user-supplied preference: when its key exists,
        // use it first. Without NanoGPT, the app falls back to the saved choice
        // (Free AI Pool by default).
        if nanoGPTConfigured { return "nanogpt" }
        return defaults.string(forKey: "ai.provider.id") ?? "freepool"
    }

    var selectedProvider: AIProviderDefinition {
        if selectedProviderID == "custom" {
            return .init(
                id: "custom",
                name: defaults.string(forKey: "ai.custom.name") ?? "Custom OpenAI-Compatible",
                baseURL: defaults.string(forKey: "ai.custom.baseURL") ?? "",
                kind: .openAICompatible,
                supportsModelDiscovery: true
            )
        }
        return providers.first(where: { $0.id == selectedProviderID }) ?? providers[0]
    }

    var baseURL: String { selectedProvider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    var selectedModel: String? { defaults.string(forKey: "ai.model.\(selectedProviderID)") }
    var isKeylessSelectedProvider: Bool { selectedProviderID == "freepool" }
    var hasAPIKey: Bool { isKeylessSelectedProvider || loadKey(providerID: selectedProviderID) != nil }

    var maskedAPIKey: String? {
        guard let key = loadKey(providerID: selectedProviderID) else { return nil }
        if key.count <= 8 { return "••••••••" }
        return String(key.prefix(4)) + "••••••••" + String(key.suffix(4))
    }

    func config() -> AIConfigResponse {
        .init(providerID: selectedProviderID, provider: selectedProvider.name, baseURL: baseURL, apiKeyConfigured: hasAPIKey, maskedAPIKey: maskedAPIKey, selectedModel: selectedModel)
    }

    func selectProvider(_ providerID: String) throws {
        guard providers.contains(where: { $0.id == providerID }) else { throw AIError.invalidResponse }
        defaults.set(providerID, forKey: "ai.provider.id")
    }

    func update(_ request: AIConfigUpdateRequest) throws -> AIConfigResponse {
        if let providerID = request.providerID { try selectProvider(providerID) }
        let providerID = selectedProviderID

        if providerID == "custom" {
            if let name = request.providerName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                defaults.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ai.custom.name")
            }
            if let url = request.baseURL {
                guard let parsed = URL(string: url), parsed.scheme == "https" else { throw AIError.invalidBaseURL }
                defaults.set(url.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: "ai.custom.baseURL")
            }
        }

        if let model = request.selectedModel {
            if model.isEmpty { defaults.removeObject(forKey: "ai.model.\(providerID)") }
            else { defaults.set(model, forKey: "ai.model.\(providerID)") }
        }

        if providerID != "freepool", let key = request.apiKey {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { deleteKey(providerID: providerID) }
            else {
                saveKey(trimmed, providerID: providerID)
                if providerID == "nanogpt" {
                    defaults.set("nanogpt", forKey: "ai.provider.id")
                }
            }
        }
        return config()
    }

    func listModels() async throws -> [AIModel] {
        if selectedProviderID == "freepool" {
            return try await listFreePoolModels()
        }
        guard let key = loadKey(providerID: selectedProviderID) else { throw AIError.missingKey }
        let provider = selectedProvider
        guard !baseURL.isEmpty else { throw AIError.invalidBaseURL }

        switch provider.kind {
        case .openAICompatible:
            guard let url = URL(string: baseURL + "/models") else { throw AIError.invalidBaseURL }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let data = try await execute(req)
            return try JSONDecoder().decode(AIModelListResponse.self, from: data).data.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        case .anthropic:
            guard let url = URL(string: baseURL + "/models") else { throw AIError.invalidBaseURL }
            var req = URLRequest(url: url)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            struct Raw: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
            let data = try await execute(req)
            let raw = try JSONDecoder().decode(Raw.self, from: data)
            return raw.data.map { AIModel(id: $0.id, ownedBy: "Anthropic") }.sorted { $0.id < $1.id }
        case .gemini:
            guard let url = URL(string: baseURL + "/models?key=\(query(key))") else { throw AIError.invalidBaseURL }
            struct Raw: Decodable { struct Model: Decodable { let name: String; let supportedGenerationMethods: [String]? }; let models: [Model] }
            let data = try await execute(URLRequest(url: url))
            let raw = try JSONDecoder().decode(Raw.self, from: data)
            return raw.models.filter { $0.supportedGenerationMethods?.contains("generateContent") ?? true }.map { AIModel(id: $0.name.replacingOccurrences(of: "models/", with: ""), ownedBy: "Google") }.sorted { $0.id < $1.id }
        case .cohere:
            guard let url = URL(string: baseURL + "/v1/models") else { throw AIError.invalidBaseURL }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            struct Raw: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
            let data = try await execute(req)
            let raw = try JSONDecoder().decode(Raw.self, from: data)
            return raw.models.map { AIModel(id: $0.name, ownedBy: "Cohere") }.sorted { $0.id < $1.id }
        }
    }

    func testConnection() async throws -> Bool {
        if selectedProviderID == "freepool" {
            let response = try await chatFreePool(.init(
                model: "free:auto",
                messages: [.init(role: "user", content: "Reply with exactly OK")],
                temperature: 0
            ))
            return !response.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        _ = try await listModels()
        return true
    }

    func chat(_ input: AIChatRequest) async throws -> AIChatResponse {
        if selectedProviderID == "freepool" {
            return try await chatFreePool(input)
        }
        guard let key = loadKey(providerID: selectedProviderID) else { throw AIError.missingKey }
        guard let model = input.model ?? selectedModel, !model.isEmpty else { throw AIError.missingModel }
        let provider = selectedProvider
        do {
            switch provider.kind {
            case .openAICompatible:
                return try await chatOpenAICompatible(provider: provider, key: key, model: model, input: input)
            case .anthropic:
                return try await chatAnthropic(key: key, model: model, input: input)
            case .gemini:
                return try await chatGemini(key: key, model: model, input: input)
            case .cohere:
                return try await chatCohere(key: key, model: model, input: input)
            }
        } catch {
            // A saved NanoGPT key always gets the first attempt. If NanoGPT is
            // temporarily unavailable or the selected model is not covered, keep
            // Nexora usable by falling back to the keyless pool for this request.
            if provider.id == "nanogpt" {
                return try await chatFreePool(.init(
                    model: "free:auto",
                    messages: input.messages,
                    temperature: input.temperature
                ))
            }
            throw error
        }
    }

    private func chatOpenAICompatible(provider: AIProviderDefinition, key: String, model: String, input: AIChatRequest) async throws -> AIChatResponse {
        guard let url = URL(string: baseURL + "/chat/completions") else { throw AIError.invalidBaseURL }
        struct Payload: Encodable { let model: String; let messages: [AIChatMessage]; let temperature: Double?; let stream = false }
        struct Choice: Decodable { let message: AIChatMessage }
        struct Raw: Decodable { let id: String?; let model: String?; let choices: [Choice] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider.id == "openrouter" {
            req.setValue("Nexora Host", forHTTPHeaderField: "X-Title")
            req.setValue("https://github.com", forHTTPHeaderField: "HTTP-Referer")
        }
        req.httpBody = try JSONEncoder().encode(Payload(model: model, messages: input.messages, temperature: input.temperature))
        let data = try await execute(req)
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard let message = raw.choices.first?.message else { throw AIError.invalidResponse }
        return .init(model: raw.model ?? model, message: message, id: raw.id)
    }

    private func chatAnthropic(key: String, model: String, input: AIChatRequest) async throws -> AIChatResponse {
        guard let url = URL(string: baseURL + "/messages") else { throw AIError.invalidBaseURL }
        let system = input.messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n")
        let messages = input.messages.filter { $0.role != "system" }.map { ["role": $0.role == "assistant" ? "assistant" : "user", "content": $0.content] }
        var body: [String: Any] = ["model": model, "max_tokens": 4096, "messages": messages]
        if !system.isEmpty { body["system"] = system }
        if let temperature = input.temperature { body["temperature"] = temperature }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        struct Raw: Decodable { struct Part: Decodable { let type: String; let text: String? }; let id: String?; let model: String; let content: [Part] }
        let data = try await execute(req)
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let text = raw.content.compactMap(\.text).joined(separator: "\n")
        return .init(model: raw.model, message: .init(role: "assistant", content: text), id: raw.id)
    }

    private func chatGemini(key: String, model: String, input: AIChatRequest) async throws -> AIChatResponse {
        guard let url = URL(string: baseURL + "/models/\(queryPath(model)):generateContent?key=\(query(key))") else { throw AIError.invalidBaseURL }
        let system = input.messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n")
        let contents: [[String: Any]] = input.messages.filter { $0.role != "system" }.map { ["role": $0.role == "assistant" ? "model" : "user", "parts": [["text": $0.content]]] }
        var body: [String: Any] = ["contents": contents]
        if !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
        if let temperature = input.temperature { body["generationConfig"] = ["temperature": temperature] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        struct Raw: Decodable { struct Candidate: Decodable { struct Content: Decodable { struct Part: Decodable { let text: String? }; let parts: [Part] }; let content: Content }; let candidates: [Candidate] }
        let data = try await execute(req)
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard let first = raw.candidates.first else { throw AIError.invalidResponse }
        return .init(model: model, message: .init(role: "assistant", content: first.content.parts.compactMap(\.text).joined(separator: "\n")), id: nil)
    }

    private func chatCohere(key: String, model: String, input: AIChatRequest) async throws -> AIChatResponse {
        guard let url = URL(string: baseURL + "/v2/chat") else { throw AIError.invalidBaseURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let messages = input.messages.map { ["role": $0.role, "content": $0.content] }
        var body: [String: Any] = ["model": model, "messages": messages]
        if let temperature = input.temperature { body["temperature"] = temperature }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        struct Raw: Decodable { struct Message: Decodable { struct Content: Decodable { let type: String; let text: String? }; let content: [Content] }; let id: String?; let message: Message }
        let data = try await execute(req)
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return .init(model: model, message: .init(role: "assistant", content: raw.message.content.compactMap(\.text).joined(separator: "\n")), id: raw.id)
    }

    private struct FreePoolEndpoint: Sendable {
        let id: String
        let name: String
        let modelsURL: String
        let chatURL: String
        let authorization: String?
        let explicitFreeOnly: Bool
    }

    private var freePoolEndpoints: [FreePoolEndpoint] {
        [
            .init(
                id: "kilo",
                name: "Kilo Gateway",
                modelsURL: "https://api.kilo.ai/api/gateway/models",
                chatURL: "https://api.kilo.ai/api/gateway/v1/chat/completions",
                authorization: nil,
                explicitFreeOnly: true
            ),
            .init(
                id: "ovh",
                name: "OVH AI Endpoints",
                modelsURL: "https://oai.endpoints.kepler.ai.cloud.ovh.net/v1/models",
                chatURL: "https://oai.endpoints.kepler.ai.cloud.ovh.net/v1/chat/completions",
                authorization: nil,
                explicitFreeOnly: false
            ),
            .init(
                id: "aihorde",
                name: "AI Horde",
                modelsURL: "https://oai.aihorde.net/v1/models",
                chatURL: "https://oai.aihorde.net/v1/chat/completions",
                authorization: "Bearer 0000000000",
                explicitFreeOnly: false
            )
        ]
    }

    private func listFreePoolModels() async throws -> [AIModel] {
        var output: [AIModel] = [
            .init(id: "free:auto", ownedBy: "FreeLLMAPI keyless pool")
        ]

        await withTaskGroup(of: [AIModel].self) { group in
            for endpoint in freePoolEndpoints {
                group.addTask { [self] in
                    do {
                        return try await discoverFreeModels(endpoint).map {
                            AIModel(id: "\(endpoint.id)::\($0)", ownedBy: endpoint.name)
                        }
                    } catch {
                        return []
                    }
                }
            }
            for await models in group { output.append(contentsOf: models) }
        }

        var seen = Set<String>()
        return output.filter { seen.insert($0.id).inserted }
    }

    private func discoverFreeModels(_ endpoint: FreePoolEndpoint) async throws -> [String] {
        guard let url = URL(string: endpoint.modelsURL) else { throw AIError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Nexora Host", forHTTPHeaderField: "User-Agent")
        if let authorization = endpoint.authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        let data = try await execute(request)
        let object = try JSONSerialization.jsonObject(with: data)
        let ids = extractModelIDs(from: object, explicitFreeOnly: endpoint.explicitFreeOnly)
        return Array(Set(ids)).sorted { freeModelRank($0) < freeModelRank($1) }
    }

    private func extractModelIDs(from value: Any, explicitFreeOnly: Bool) -> [String] {
        if let array = value as? [Any] {
            return array.flatMap { extractModelIDs(from: $0, explicitFreeOnly: explicitFreeOnly) }
        }
        guard let dictionary = value as? [String: Any] else { return [] }

        var output: [String] = []
        if let candidate = (dictionary["id"] as? String)
            ?? (dictionary["model"] as? String)
            ?? (dictionary["name"] as? String) {
            let isExplicitlyFree = (dictionary["free"] as? Bool) == true
                || (dictionary["isFree"] as? Bool) == true
                || candidate.localizedCaseInsensitiveContains(":free")
            if !explicitFreeOnly || isExplicitlyFree { output.append(candidate) }
        }
        for child in dictionary.values where child is [Any] || child is [String: Any] {
            output.append(contentsOf: extractModelIDs(from: child, explicitFreeOnly: explicitFreeOnly))
        }
        return output
    }

    private func chatFreePool(_ input: AIChatRequest) async throws -> AIChatResponse {
        let requested = input.model ?? selectedModel ?? "free:auto"
        if requested != "free:auto" {
            guard let route = parseFreePoolModel(requested) else { throw AIError.missingModel }
            return try await chatFreeEndpoint(providerID: route.providerID, modelID: route.modelID, input: input)
        }

        let candidates = try await listFreePoolModels()
            .filter { $0.id != "free:auto" }
            .sorted { freeModelRank($0.id) < freeModelRank($1.id) }

        var failures: [String] = []
        for candidate in candidates.prefix(10) {
            guard let route = parseFreePoolModel(candidate.id) else { continue }
            do {
                return try await chatFreeEndpoint(providerID: route.providerID, modelID: route.modelID, input: input)
            } catch {
                failures.append("\(route.providerID): \(error.localizedDescription)")
            }
        }
        let detail = failures.isEmpty
            ? "No keyless free model is reachable right now."
            : failures.prefix(3).joined(separator: " · ")
        throw AIError.remote(503, "Free AI providers are temporarily unavailable. \(detail)")
    }

    private func chatFreeEndpoint(
        providerID: String,
        modelID: String,
        input: AIChatRequest
    ) async throws -> AIChatResponse {
        guard let endpoint = freePoolEndpoints.first(where: { $0.id == providerID }),
              let url = URL(string: endpoint.chatURL) else { throw AIError.invalidBaseURL }

        struct Payload: Encodable {
            let model: String
            let messages: [AIChatMessage]
            let temperature: Double?
            let maxTokens: Int?
            let stream = false
            enum CodingKeys: String, CodingKey {
                case model, messages, temperature, stream
                case maxTokens = "max_tokens"
            }
        }
        struct Choice: Decodable { let message: AIChatMessage }
        struct Raw: Decodable { let id: String?; let model: String?; let choices: [Choice] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = providerID == "aihorde" ? 120 : 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Nexora Host", forHTTPHeaderField: "User-Agent")
        if let authorization = endpoint.authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(Payload(
            model: modelID,
            messages: input.messages,
            temperature: input.temperature,
            maxTokens: providerID == "aihorde" ? 1024 : nil
        ))

        let data = try await execute(request)
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard let message = raw.choices.first?.message else { throw AIError.invalidResponse }
        return .init(model: "\(providerID)::\(raw.model ?? modelID)", message: message, id: raw.id)
    }

    private func parseFreePoolModel(_ value: String) -> (providerID: String, modelID: String)? {
        guard let range = value.range(of: "::") else { return nil }
        let provider = String(value[..<range.lowerBound])
        let model = String(value[range.upperBound...])
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        return (provider, model)
    }

    private func freeModelRank(_ value: String) -> Int {
        let lower = value.lowercased()
        var score = 100
        if lower.contains("coder") || lower.contains("code") { score -= 50 }
        if lower.contains("qwen") { score -= 20 }
        if lower.contains("gpt") { score -= 15 }
        if lower.contains("llama") { score -= 10 }
        if lower.hasPrefix("kilo::") { score -= 8 }
        if lower.hasPrefix("ovh::") { score -= 5 }
        if lower.hasPrefix("aihorde::") { score += 20 }
        return score
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw parseRemoteError(status: http.statusCode, data: data) }
        return data
    }

    private func parseRemoteError(status: Int, data: Data) -> Error {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return AIError.remote(status, String(data: data, encoding: .utf8) ?? "") }
        let nested = json["error"] as? [String: Any]
        let source = nested ?? json
        let code = (source["code"] as? String) ?? (json["code"] as? String)
        if status == 402 || code == "insufficient_balance" {
            return AIError.insufficientBalance(
                available: number(source["availableBalance"]) ?? number(source["available_balance"]) ?? number(source["available"]),
                required: number(source["requiredBalance"]) ?? number(source["required_balance"]) ?? number(source["required"]),
                subscriptionCovered: bool(source["baseModelCoveredBySubscription"]) ?? bool(source["base_model_covered_by_subscription"]),
                freeCovered: bool(source["baseModelCoveredByFreeAccess"]) ?? bool(source["base_model_covered_by_free_access"])
            )
        }
        let message = (source["message"] as? String) ?? (json["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
        return AIError.remote(status, message)
    }

    private func loadKey(providerID: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: providerID, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveKey(_ key: String, providerID: String) {
        deleteKey(providerID: providerID)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: providerID, kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(item as CFDictionary, nil)
    }

    private func deleteKey(providerID: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: providerID]
        SecItemDelete(query as CFDictionary)
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
        if let value = value as? String { return value.lowercased() == "true" ? true : value.lowercased() == "false" ? false : nil }
        return nil
    }

    private func query(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value }
    private func queryPath(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value }
}
