import Foundation
import Security

struct DiscordEmbedConfig: Codable, Sendable, Equatable {
    var title: String = ""
    var description: String = ""
    var footer: String = ""
    var imageURL: String = ""
    var thumbnailURL: String = ""
    var timestamp: Bool = false
}

struct WebhookConfig: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case discord = "Discord"
        case generic = "Generic HTTP"
        var id: String { rawValue }
    }

    let id: String
    var projectID: String?
    var name: String
    var kind: Kind
    var method: String
    var username: String?
    var avatarURL: String?
    var messageTemplate: String
    var headers: [String: String]
    var enabled: Bool
    var embed: DiscordEmbedConfig? = nil
}

struct WebhookDelivery: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let webhookID: String
    let timestamp: Date
    let statusCode: Int?
    let succeeded: Bool
    let message: String
}

final class WebhookManager: @unchecked Sendable {
    enum WebhookError: Error, LocalizedError {
        case invalidURL
        case missingSecret
        case invalidMethod
        case invalidResponse
        case remote(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Webhook URL is invalid."
            case .missingSecret: return "Webhook URL is missing."
            case .invalidMethod: return "Webhook method is not supported."
            case .invalidResponse: return "Webhook returned an unreadable response."
            case .remote(let code, let text): return text.isEmpty ? "Webhook failed with HTTP \(code)." : "Webhook failed with HTTP \(code): \(text)"
            }
        }
    }

    private let defaults = UserDefaults.standard
    private let service = "app.nexorahost.webhooks"
    private let session: URLSession
    private let history: HistoryStore
    private let lock = NSLock()

    init(history: HistoryStore, session: URLSession = .shared) {
        self.history = history
        self.session = session
    }

    func list(projectID: String? = nil) -> [WebhookConfig] {
        lock.lock(); defer { lock.unlock() }
        let all = loadConfigs()
        return projectID.map { id in all.filter { $0.projectID == nil || $0.projectID == id } } ?? all
    }

    func save(_ config: WebhookConfig, secretURL: String?) throws {
        lock.lock(); defer { lock.unlock() }
        if let secretURL {
            let trimmed = secretURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw WebhookError.invalidURL }
            saveSecret(trimmed, account: config.id)
        }
        var configs = loadConfigs()
        if let index = configs.firstIndex(where: { $0.id == config.id }) { configs[index] = config }
        else { configs.append(config) }
        persist(configs)
    }

    func delete(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        var configs = loadConfigs()
        configs.removeAll { $0.id == id }
        persist(configs)
        deleteSecret(account: id)
    }

    func maskedURL(_ id: String) -> String? {
        guard let value = loadSecret(account: id), let url = URL(string: value) else { return nil }
        let host = url.host ?? "webhook"
        return "\(url.scheme ?? "https")://\(host)/••••••••"
    }

    func send(webhookID: String, variables: [String: String] = [:]) async throws -> WebhookDelivery {
        guard let config = list().first(where: { $0.id == webhookID }) else { throw WebhookError.missingSecret }
        guard config.enabled else { throw WebhookError.missingSecret }
        guard let rawURL = loadSecret(account: webhookID), let url = URL(string: rawURL) else { throw WebhookError.missingSecret }

        let method = config.kind == .discord ? "POST" : config.method.uppercased()
        guard ["POST", "PUT", "PATCH"].contains(method) else { throw WebhookError.invalidMethod }

        let resolved = resolve(config.messageTemplate, variables: variables)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        config.headers.forEach { request.setValue(resolve($0.value, variables: variables), forHTTPHeaderField: $0.key) }

        if config.kind == .discord {
            var body: [String: Any] = ["content": resolved]
            if let username = config.username, !username.isEmpty { body["username"] = username }
            if let avatar = config.avatarURL, !avatar.isEmpty { body["avatar_url"] = avatar }
            if let embed = config.embed, !embed.title.isEmpty || !embed.description.isEmpty {
                var item: [String: Any] = [:]
                if !embed.title.isEmpty { item["title"] = resolve(embed.title, variables: variables) }
                if !embed.description.isEmpty { item["description"] = resolve(embed.description, variables: variables) }
                if !embed.footer.isEmpty { item["footer"] = ["text": resolve(embed.footer, variables: variables)] }
                if !embed.imageURL.isEmpty { item["image"] = ["url": embed.imageURL] }
                if !embed.thumbnailURL.isEmpty { item["thumbnail"] = ["url": embed.thumbnailURL] }
                if embed.timestamp { item["timestamp"] = ISO8601DateFormatter().string(from: .now) }
                body["embeds"] = [item]
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if let data = resolved.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil {
            request.httpBody = data
        } else {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["message": resolved])
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebhookError.invalidResponse }
        let responseText = String(data: data, encoding: .utf8) ?? ""
        let ok = (200..<300).contains(http.statusCode)
        let delivery = WebhookDelivery(id: UUID().uuidString, webhookID: webhookID, timestamp: .now, statusCode: http.statusCode, succeeded: ok, message: responseText)
        appendDelivery(delivery)
        if let projectID = config.projectID {
            history.append(projectID: projectID, kind: .webhook, title: ok ? "Webhook sent" : "Webhook failed", detail: config.name)
        }
        if !ok { throw WebhookError.remote(http.statusCode, responseText) }
        return delivery
    }

    func deliveries(limit: Int = 100) -> [WebhookDelivery] {
        let key = "nexora.webhook.deliveries"
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder.webhooks.decode([WebhookDelivery].self, from: data) else { return [] }
        return Array(value.sorted { $0.timestamp > $1.timestamp }.prefix(limit))
    }

    private func appendDelivery(_ delivery: WebhookDelivery) {
        let key = "nexora.webhook.deliveries"
        var current = deliveries(limit: 200)
        current.append(delivery)
        if current.count > 200 { current.removeFirst(current.count - 200) }
        if let data = try? JSONEncoder.webhooks.encode(current) { defaults.set(data, forKey: key) }
    }

    private func resolve(_ template: String, variables: [String: String]) -> String {
        var value = template
        variables.forEach { value = value.replacingOccurrences(of: "{{\($0.key)}}", with: $0.value) }
        value = value.replacingOccurrences(of: "{{timestamp}}", with: ISO8601DateFormatter().string(from: .now))
        return value
    }

    private func loadConfigs() -> [WebhookConfig] {
        guard let data = defaults.data(forKey: "nexora.webhooks"), let value = try? JSONDecoder.webhooks.decode([WebhookConfig].self, from: data) else { return [] }
        return value
    }

    private func persist(_ configs: [WebhookConfig]) {
        if let data = try? JSONEncoder.webhooks.encode(configs) { defaults.set(data, forKey: "nexora.webhooks") }
    }

    private func saveSecret(_ value: String, account: String) {
        deleteSecret(account: account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    private func loadSecret(account: String) -> String? {
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

    private func deleteSecret(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

private extension JSONEncoder {
    static var webhooks: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        return value
    }
}

private extension JSONDecoder {
    static var webhooks: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}
