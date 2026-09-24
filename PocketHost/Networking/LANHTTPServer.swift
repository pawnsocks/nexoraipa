import Foundation
import Security
import NIOCore
import NIOHTTP1
import NIOTransportServices

final class APIKeyStore: @unchecked Sendable {
    private let service = "app.pockethost.local"
    private let account = "local-api-key"
    let value: String

    init() {
        if let existing = Self.load(service: service, account: account) {
            value = existing
        } else {
            let generated = Self.generate()
            Self.save(generated, service: service, account: account)
            value = generated
        }
    }

    private static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, rawBuffer.count, baseAddress)
        }
        if status == errSecSuccess {
            return Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func load(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    private static func save(_ value: String, service: String, account: String) {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(identity as CFDictionary)
        var item = identity
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

final class LANHTTPServer: @unchecked Sendable {
    private var group: NIOTSEventLoopGroup?
    private var channel: Channel?
    private var bonjour: NetService?
    private let store: KeyValueStore
    private let sqlite: SQLiteStore
    private let metrics: MetricsBox
    private let supervisor: RuntimeSupervisor
    private let autoTune: AutoTuneEngine
    private let apiKeyStore: APIKeyStore
    private let projects: ProjectManager
    private let logs: LogBroker
    private let projectDB: ProjectDatabaseManager
    private let packs: RuntimePackManager
    private let ai: AIProviderService
    let requestCounter = RequestCounter()

    init(
        store: KeyValueStore,
        sqlite: SQLiteStore,
        metrics: MetricsBox,
        supervisor: RuntimeSupervisor,
        autoTune: AutoTuneEngine,
        apiKeyStore: APIKeyStore,
        projects: ProjectManager,
        logs: LogBroker,
        projectDB: ProjectDatabaseManager,
        packs: RuntimePackManager,
        ai: AIProviderService
    ) {
        self.store = store
        self.sqlite = sqlite
        self.metrics = metrics
        self.supervisor = supervisor
        self.autoTune = autoTune
        self.apiKeyStore = apiKeyStore
        self.projects = projects
        self.logs = logs
        self.projectDB = projectDB
        self.packs = packs
        self.ai = ai
    }

    var apiKey: String { apiKeyStore.value }
    var isRunning: Bool { channel?.isActive == true }

    func start(port: Int = 8080) async throws {
        guard channel == nil else { return }
        let group = NIOTSEventLoopGroup(loopCount: 1)
        self.group = group
        let bootstrap = NIOTSListenerBootstrap(group: group)
            .childChannelInitializer { [store, sqlite, metrics, supervisor, autoTune, apiKeyStore, projects, logs, projectDB, packs, ai, requestCounter] channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(APIHTTPHandler(
                        store: store,
                        sqlite: sqlite,
                        metrics: metrics,
                        supervisor: supervisor,
                        autoTune: autoTune,
                        apiKey: apiKeyStore.value,
                        projects: projects,
                        logs: logs,
                        projectDB: projectDB,
                        packs: packs,
                        ai: ai,
                        counter: requestCounter
                    ))
                }
            }
        let channel = try await bootstrap.bind(host: "0.0.0.0", port: port).get()
        self.channel = channel
        let service = NetService(domain: "local.", type: "_http._tcp.", name: "PocketHost API", port: Int32(port))
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "api": Data("/api/v1".utf8),
            "version": Data("v1".utf8),
            "logs-ws-port": Data("8081".utf8),
        ]))
        service.publish()
        bonjour = service
    }

    func stop() async {
        bonjour?.stop(); bonjour = nil
        if let channel { try? await channel.close().get() }
        channel = nil
        if let group { try? await group.shutdownGracefully() }
        self.group = nil
    }
}

private struct APIErrorBody: Codable { let error: String; let message: String }
private struct APIInfo: Codable { let name: String; let apiVersion: String; let status: String; let docs: String; let logWebSocketPort: Int }
private struct APIStatus: Codable {
    let name: String
    let apiVersion: String
    let status: String
    let metrics: MetricsSnapshot
    let profile: TuneProfile
    let policy: TunedPolicy
    let runtimes: [RuntimeStatus]
    let keyValueCount: Int
    let projectCount: Int
    let runtimePacks: Int
    let aiConfigured: Bool
}
private struct RuntimeExecuteRequest: Codable { let code: String }
private struct RuntimeExecuteResponse: Codable { let runtime: RuntimeKind; let result: RuntimeResult }
private struct KVWriteRequest: Codable { let value: String; let encoding: String? }
private struct KVValueResponse: Codable { let key: String; let value: String; let encoding: String }
private struct KVListResponse: Codable { let keys: [String]; let count: Int }
private struct AutoTuneResponse: Codable { let profile: TuneProfile; let policy: TunedPolicy }
private struct AutoTuneProfileRequest: Codable { let profile: String }
private struct ProjectLifecycleResponse: Codable { let project: ProjectRecord; let result: RuntimeResult? }

private final class APIHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let store: KeyValueStore
    private let sqlite: SQLiteStore
    private let metrics: MetricsBox
    private let supervisor: RuntimeSupervisor
    private let autoTune: AutoTuneEngine
    private let apiKey: String
    private let projects: ProjectManager
    private let logs: LogBroker
    private let projectDB: ProjectDatabaseManager
    private let packs: RuntimePackManager
    private let ai: AIProviderService
    private let counter: RequestCounter
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    private var bodyTooLarge = false
    private let maxBodyBytes = 32 * 1024 * 1024

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(
        store: KeyValueStore,
        sqlite: SQLiteStore,
        metrics: MetricsBox,
        supervisor: RuntimeSupervisor,
        autoTune: AutoTuneEngine,
        apiKey: String,
        projects: ProjectManager,
        logs: LogBroker,
        projectDB: ProjectDatabaseManager,
        packs: RuntimePackManager,
        ai: AIProviderService,
        counter: RequestCounter
    ) {
        self.store = store
        self.sqlite = sqlite
        self.metrics = metrics
        self.supervisor = supervisor
        self.autoTune = autoTune
        self.apiKey = apiKey
        self.projects = projects
        self.logs = logs
        self.projectDB = projectDB
        self.packs = packs
        self.ai = ai
        self.counter = counter
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let request):
            head = request
            body.clear()
            bodyTooLarge = false
        case .body(var chunk):
            if body.readableBytes + chunk.readableBytes > maxBodyBytes { bodyTooLarge = true }
            else { body.writeBuffer(&chunk) }
        case .end:
            counter.hit()
            handleRequest(context: context)
        }
    }

    private func handleRequest(context: ChannelHandlerContext) {
        guard let head else {
            respondError(context: context, status: .badRequest, error: "bad_request", message: "Invalid HTTP request.")
            return
        }
        if bodyTooLarge {
            respondError(context: context, status: .payloadTooLarge, error: "payload_too_large", message: "Request body exceeds 32 MB.")
            return
        }
        let components = urlComponents(head.uri)
        let path = components?.path ?? head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

        if head.method == .OPTIONS { respond(context: context, status: .noContent, body: Data()); return }
        if head.method == .GET && (path == "/" || path == "/api/v1") {
            respondJSON(context: context, status: .ok, value: APIInfo(name: "PocketHost API", apiVersion: "v1", status: "ok", docs: "OpenAPI.yaml", logWebSocketPort: 8081)); return
        }
        if head.method == .GET && (path == "/health" || path == "/api/v1/health") {
            let m = metrics.get()
            respondJSON(context: context, status: .ok, value: ["status": "ok", "thermal": m.thermal, "memoryMB": String(format: "%.1f", m.residentMemoryMB)]); return
        }
        guard path.hasPrefix("/api/v1/") else {
            respondError(context: context, status: .notFound, error: "not_found", message: "Use the /api/v1 API."); return
        }
        guard isAuthorized(head) else {
            respondError(context: context, status: .unauthorized, error: "unauthorized", message: "Send Authorization: Bearer <API_KEY>."); return
        }
        routeV1(context: context, head: head, path: path, components: components)
    }

    private func routeV1(context: ChannelHandlerContext, head: HTTPRequestHead, path: String, components: URLComponents?) {
        if head.method == .GET && path == "/api/v1/status" {
            respondJSON(context: context, status: .ok, value: APIStatus(
                name: "PocketHost", apiVersion: "v1", status: "running", metrics: metrics.get(), profile: autoTune.profile, policy: autoTune.policy,
                runtimes: supervisor.statuses(), keyValueCount: store.count, projectCount: projects.list().count, runtimePacks: packs.list().count, aiConfigured: ai.hasAPIKey
            )); return
        }
        if head.method == .GET && path == "/api/v1/metrics" { respondJSON(context: context, status: .ok, value: metrics.get()); return }
        if head.method == .GET && path == "/api/v1/runtimes" { respondJSON(context: context, status: .ok, value: supervisor.statuses()); return }

        if path.hasPrefix("/api/v1/runtimes/") && path.hasSuffix("/execute") && head.method == .POST {
            let parts = path.split(separator: "/")
            guard parts.count == 5, let kind = RuntimeKind.apiValue(String(parts[3])) else { respondError(context: context, status: .badRequest, error: "invalid_runtime", message: "Unknown runtime."); return }
            guard let request: RuntimeExecuteRequest = decodeBody(RuntimeExecuteRequest.self) else { respondError(context: context, status: .badRequest, error: "invalid_json", message: "Expected {\"code\":\"...\"}."); return }
            guard request.code.utf8.count <= 256_000 else { respondError(context: context, status: .payloadTooLarge, error: "code_too_large", message: "Code is limited to 256 KB."); return }
            let result = supervisor.run(kind: kind, code: request.code)
            respondJSON(context: context, status: result.succeeded ? .ok : .unprocessableEntity, value: RuntimeExecuteResponse(runtime: kind, result: result)); return
        }

        if handleProjects(context: context, head: head, path: path, components: components) { return }

        if head.method == .GET && path == "/api/v1/runtime-packs" { respondJSON(context: context, status: .ok, value: packs.list()); return }
        if head.method == .POST && path == "/api/v1/runtime-packs/install" {
            guard let request: RuntimePackInstallRequest = decodeBody(RuntimePackInstallRequest.self) else { respondError(context: context, status: .badRequest, error: "invalid_json", message: "Invalid runtime-pack body."); return }
            do { respondJSON(context: context, status: .created, value: try packs.install(request)) }
            catch { respondError(context: context, status: .unprocessableEntity, error: "pack_install_failed", message: String(describing: error)) }
            return
        }

        if handleAI(context: context, head: head, path: path) { return }

        if head.method == .GET && path == "/api/v1/kv" {
            let keys = store.keys(); respondJSON(context: context, status: .ok, value: KVListResponse(keys: keys, count: keys.count)); return
        }
        if path.hasPrefix("/api/v1/kv/") {
            let encodedKey = String(path.dropFirst("/api/v1/kv/".count)); let key = encodedKey.removingPercentEncoding ?? encodedKey
            guard !key.isEmpty else { respondError(context: context, status: .badRequest, error: "invalid_key", message: "Key cannot be empty."); return }
            switch head.method {
            case .GET:
                guard let data = store.get(key) else { respondError(context: context, status: .notFound, error: "key_not_found", message: "No value exists for this key."); return }
                if let text = String(data: data, encoding: .utf8) { respondJSON(context: context, status: .ok, value: KVValueResponse(key: key, value: text, encoding: "utf8")) }
                else { respondJSON(context: context, status: .ok, value: KVValueResponse(key: key, value: data.base64EncodedString(), encoding: "base64")) }
            case .PUT, .POST:
                guard let request: KVWriteRequest = decodeBody(KVWriteRequest.self) else { respondError(context: context, status: .badRequest, error: "invalid_json", message: "Expected value and optional encoding."); return }
                let encoding = request.encoding?.lowercased() ?? "utf8"
                let data: Data? = (encoding == "base64") ? Data(base64Encoded: request.value) : ((encoding == "utf8" || encoding == "text") ? Data(request.value.utf8) : nil)
                guard let data else { respondError(context: context, status: .badRequest, error: "invalid_encoding", message: "Encoding must be utf8 or base64."); return }
                guard data.count <= 1_048_576 else { respondError(context: context, status: .payloadTooLarge, error: "value_too_large", message: "Values are limited to 1 MB."); return }
                store.set(key, value: data); sqlite.set(key, value: data)
                respondJSON(context: context, status: .created, value: KVValueResponse(key: key, value: request.value, encoding: encoding))
            case .DELETE:
                store.delete(key); respond(context: context, status: .noContent, body: Data())
            default: respondError(context: context, status: .methodNotAllowed, error: "method_not_allowed", message: "Method not allowed.")
            }
            return
        }

        if head.method == .GET && path == "/api/v1/autotune" { respondJSON(context: context, status: .ok, value: AutoTuneResponse(profile: autoTune.profile, policy: autoTune.policy)); return }
        if (head.method == .PUT || head.method == .POST) && path == "/api/v1/autotune/profile" {
            guard let request: AutoTuneProfileRequest = decodeBody(AutoTuneProfileRequest.self), let profile = TuneProfile.allCases.first(where: { $0.rawValue.lowercased() == request.profile.lowercased() }) else {
                respondError(context: context, status: .badRequest, error: "invalid_profile", message: "Profile must be Auto, Performance, Balanced or Battery Saver."); return
            }
            let snapshot = metrics.get(); let applied = autoTune.setProfile(profile, isCharging: snapshot.isCharging); let policy = autoTune.evaluate(snapshot)
            respondJSON(context: context, status: .ok, value: AutoTuneResponse(profile: applied, policy: policy)); return
        }

        respondError(context: context, status: .notFound, error: "not_found", message: "API endpoint not found.")
    }

    private func handleProjects(context: ChannelHandlerContext, head: HTTPRequestHead, path: String, components: URLComponents?) -> Bool {
        guard path == "/api/v1/projects" || path.hasPrefix("/api/v1/projects/") else { return false }
        if path == "/api/v1/projects" {
            if head.method == .GET { respondJSON(context: context, status: .ok, value: projects.list()); return true }
            if head.method == .POST {
                guard let request: CreateProjectRequest = decodeBody(CreateProjectRequest.self), let runtime = RuntimeKind.apiValue(request.runtime) else { respondError(context: context, status: .badRequest, error: "invalid_project", message: "Expected name, runtime and optional entrypoint."); return true }
                do { respondJSON(context: context, status: .created, value: try projects.create(name: request.name, runtime: runtime, entrypoint: request.entrypoint)) }
                catch { respondError(context: context, status: .badRequest, error: "project_create_failed", message: String(describing: error)) }
                return true
            }
            respondError(context: context, status: .methodNotAllowed, error: "method_not_allowed", message: "Method not allowed."); return true
        }

        let parts = path.split(separator: "/")
        guard parts.count >= 4 else { return false }
        let id = String(parts[3])
        guard let project = projects.get(id) else { respondError(context: context, status: .notFound, error: "project_not_found", message: "Project not found."); return true }

        if parts.count == 4 {
            if head.method == .GET { respondJSON(context: context, status: .ok, value: project) }
            else if head.method == .DELETE {
                supervisor.stopProject(projectID: id)
                do { try projects.delete(id); respond(context: context, status: .noContent, body: Data()) }
                catch { respondError(context: context, status: .internalServerError, error: "delete_failed", message: String(describing: error)) }
            } else { respondError(context: context, status: .methodNotAllowed, error: "method_not_allowed", message: "Method not allowed.") }
            return true
        }

        let action = String(parts[4])
        switch action {
        case "deployments":
            if head.method == .GET {
                do { respondJSON(context: context, status: .ok, value: try projects.listDeployments(id)) }
                catch { respondError(context: context, status: .badRequest, error: "deployment_list_failed", message: String(describing: error)) }
            } else if head.method == .POST {
                guard let request: CreateDeploymentRequest = decodeBody(CreateDeploymentRequest.self) else { respondError(context: context, status: .badRequest, error: "invalid_json", message: "Invalid deployment body."); return true }
                do {
                    let deployment = try projects.deploy(projectID: id, request: request)
                    supervisor.stopProject(projectID: id)
                    respondJSON(context: context, status: .created, value: deployment)
                } catch { respondError(context: context, status: .unprocessableEntity, error: "deploy_failed", message: String(describing: error)) }
            } else { respondError(context: context, status: .methodNotAllowed, error: "method_not_allowed", message: "Method not allowed.") }
        case "start":
            guard head.method == .POST else { respondError(context: context, status: .methodNotAllowed, error: "method_not_allowed", message: "POST required."); return true }
            do {
                let (current, source) = try projects.entrypointSource(id)
                let result = supervisor.startProject(projectID: id, kind: current.runtime, code: source)
                let updated = try projects.setState(id, result.succeeded ? .running : .error)
                respondJSON(context: context, status: result.succeeded ? .ok : .unprocessableEntity, value: ProjectLifecycleResponse(project: updated, result: result))
            } catch { respondError(context: context, status: .unprocessableEntity, error: "start_failed", message: String(describing: error)) }
        case "stop":
            guard head.method == .POST else { respondError(context: context, status: .methodNotAllowed, error: "method_not_allowed", message: "POST required."); return true }
            supervisor.stopProject(projectID: id)
            do { respondJSON(context: context, status: .ok, value: ProjectLifecycleResponse(project: try projects.setState(id, .stopped), result: nil)) }
            catch { respondError(context: context, status: .internalServerError, error: "stop_failed", message: String(describing: error)) }
        case "restart":
            guard head.method == .POST else { respondError(context: context, status: .methodNotAllowed, error: "method_not_allowed", message: "POST required."); return true }
            do {
                supervisor.stopProject(projectID: id)
                let (current, source) = try projects.entrypointSource(id)
                let result = supervisor.startProject(projectID: id, kind: current.runtime, code: source)
                let updated = try projects.setState(id, result.succeeded ? .running : .error)
                respondJSON(context: context, status: result.succeeded ? .ok : .unprocessableEntity, value: ProjectLifecycleResponse(project: updated, result: result))
            } catch { respondError(context: context, status: .unprocessableEntity, error: "restart_failed", message: String(describing: error)) }
        case "files":
            guard head.method == .GET else { respondError(context: context, status: .methodNotAllowed, error: "method_not_allowed", message: "GET required."); return true }
            let target = queryValue("path", components: components) ?? ""
            do { respondJSON(context: context, status: .ok, value: try projects.listFiles(projectID: id, path: target)) }
            catch { respondError(context: context, status: .badRequest, error: "files_failed", message: String(describing: error)) }
        case "file":
            guard let target = queryValue("path", components: components), !target.isEmpty else { respondError(context: context, status: .badRequest, error: "missing_path", message: "Use ?path=relative/file."); return true }
            do {
                switch head.method {
                case .GET: respondJSON(context: context, status: .ok, value: try projects.readFile(projectID: id, path: target))
                case .PUT, .POST:
                    guard let request: FileWriteRequest = decodeBody(FileWriteRequest.self) else { respondError(context: context, status: .badRequest, error: "invalid_json", message: "Expected content and optional encoding."); return true }
                    respondJSON(context: context, status: .ok, value: try projects.writeFile(projectID: id, path: target, request: request))
                case .DELETE: try projects.deleteFile(projectID: id, path: target); respond(context: context, status: .noContent, body: Data())
                default: respondError(context: context, status: .methodNotAllowed, error: "method_not_allowed", message: "Method not allowed.")
                }
            } catch { respondError(context: context, status: .badRequest, error: "file_failed", message: String(describing: error)) }
        case "logs":
            guard head.method == .GET else { respondError(context: context, status: .methodNotAllowed, error: "method_not_allowed", message: "GET required."); return true }
            let requested = Int(queryValue("limit", components: components) ?? "200") ?? 200
            let limit = min(max(requested, 1), 500)
            respondJSON(context: context, status: .ok, value: logs.recent(projectID: id, limit: limit))
        case "db":
            guard parts.count == 6, String(parts[5]) == "query", head.method == .POST else { respondError(context: context, status: .notFound, error: "not_found", message: "Use POST /projects/:id/db/query."); return true }
            guard let request: SQLRequest = decodeBody(SQLRequest.self) else { respondError(context: context, status: .badRequest, error: "invalid_json", message: "Expected {\"sql\":\"...\"}."); return true }
            do { respondJSON(context: context, status: .ok, value: try projectDB.execute(projectID: id, sql: request.sql)) }
            catch { respondError(context: context, status: .unprocessableEntity, error: "sql_failed", message: String(describing: error)) }
        default: respondError(context: context, status: .notFound, error: "not_found", message: "Project endpoint not found.")
        }
        return true
    }

    private func handleAI(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) -> Bool {
        guard path == "/api/v1/ai/config" || path == "/api/v1/ai/models" || path == "/api/v1/ai/chat" else { return false }
        if path == "/api/v1/ai/config" {
            if head.method == .GET { respondJSON(context: context, status: .ok, value: ai.config()); return true }
            if head.method == .PUT || head.method == .POST {
                guard let request: AIConfigUpdateRequest = decodeBody(AIConfigUpdateRequest.self) else { respondError(context: context, status: .badRequest, error: "invalid_json", message: "Invalid AI config."); return true }
                do { respondJSON(context: context, status: .ok, value: try ai.update(request)) }
                catch { respondError(context: context, status: .badRequest, error: "ai_config_failed", message: error.localizedDescription) }
                return true
            }
            respondError(context: context, status: .methodNotAllowed, error: "method_not_allowed", message: "Method not allowed."); return true
        }
        if path == "/api/v1/ai/models" {
            guard head.method == .GET else { respondError(context: context, status: .methodNotAllowed, error: "method_not_allowed", message: "GET required."); return true }
            context.eventLoop.makeFutureWithTask { [ai] in try await ai.listModels() }.whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let models): self.respondJSON(context: context, status: .ok, value: models)
                case .failure(let error): self.respondError(context: context, status: .badGateway, error: "ai_models_failed", message: error.localizedDescription)
                }
            }
            return true
        }
        if path == "/api/v1/ai/chat" {
            guard head.method == .POST else { respondError(context: context, status: .methodNotAllowed, error: "method_not_allowed", message: "POST required."); return true }
            guard let request: AIChatRequest = decodeBody(AIChatRequest.self), !request.messages.isEmpty else { respondError(context: context, status: .badRequest, error: "invalid_json", message: "Expected model (optional) and messages."); return true }
            context.eventLoop.makeFutureWithTask { [ai] in try await ai.chat(request) }.whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let response): self.respondJSON(context: context, status: .ok, value: response)
                case .failure(let error): self.respondError(context: context, status: .badGateway, error: "ai_chat_failed", message: error.localizedDescription)
                }
            }
            return true
        }
        return false
    }

    private func isAuthorized(_ head: HTTPRequestHead) -> Bool {
        guard let value = head.headers.first(name: "Authorization") else { return false }
        return value == "Bearer \(apiKey)"
    }
    private func decodeBody<T: Decodable>(_ type: T.Type) -> T? {
        var copy = body; let bytes = copy.readBytes(length: copy.readableBytes) ?? []
        return try? decoder.decode(type, from: Data(bytes))
    }
    private func urlComponents(_ uri: String) -> URLComponents? { URLComponents(string: "http://localhost\(uri)") }
    private func queryValue(_ name: String, components: URLComponents?) -> String? { components?.queryItems?.first(where: { $0.name == name })?.value }

    private func respondJSON<T: Encodable>(context: ChannelHandlerContext, status: HTTPResponseStatus, value: T) {
        do { respond(context: context, status: status, contentType: "application/json; charset=utf-8", body: try encoder.encode(value)) }
        catch { respondError(context: context, status: .internalServerError, error: "encoding_error", message: "Could not encode API response.") }
    }
    private func respondError(context: ChannelHandlerContext, status: HTTPResponseStatus, error: String, message: String) {
        respondJSON(context: context, status: status, value: APIErrorBody(error: error, message: message))
    }
    private func respond(context: ChannelHandlerContext, status: HTTPResponseStatus, contentType: String = "application/json; charset=utf-8", body data: Data) {
        var buffer = context.channel.allocator.buffer(capacity: data.count); buffer.writeBytes(data)
        var headers = HTTPHeaders()
        if !data.isEmpty { headers.add(name: "Content-Type", value: contentType) }
        headers.add(name: "Content-Length", value: "\(buffer.readableBytes)")
        headers.add(name: "Access-Control-Allow-Origin", value: "*")
        headers.add(name: "Access-Control-Allow-Headers", value: "Authorization, Content-Type")
        headers.add(name: "Access-Control-Allow-Methods", value: "GET, POST, PUT, DELETE, OPTIONS")
        headers.add(name: "Cache-Control", value: "no-store")
        headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: status, headers: headers))), promise: nil)
        if !data.isEmpty { context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil) }
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }
}
