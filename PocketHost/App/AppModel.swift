import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var metrics = MetricsSnapshot()
    @Published var policy = TunedPolicy(workerLimit: 2, cacheLimitMB: 64, tickIntervalMS: 500, suspendIdleRuntimes: true, note: "Balanced baseline")
    @Published var profile: TuneProfile = .balanced
    @Published var serverRunning = false
    @Published var serverMessage = "Stopped"
    @Published var runtimeStatuses: [RuntimeStatus] = []
    @Published var terminalOutput = "PocketHost terminal\nType help for commands."
    @Published var editorCode = "console.log('Hello from PocketHost');\n2 + 2"

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

    var apiKey: String { apiKeyStore.value }

    private let sampler = SystemMetricsSampler()
    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        runtimeStatuses = supervisor.statuses()
        do {
            try await server.start(port: 8080)
            try logSocket.start(port: 8081)
            serverRunning = true
            serverMessage = "REST :8080 · WebSocket :8081"
        } catch {
            serverRunning = server.isRunning
            serverMessage = "API error: \(error.localizedDescription)"
        }

        while !Task.isCancelled {
            let sample = sampler.sample(requestsPerSecond: server.requestCounter.rps(), keyValueCount: store.count)
            metrics = sample
            metricsBox.set(sample)
            if autoTune.profile == .turbo && !sample.isCharging {
                _ = autoTune.setProfile(.turbo, isCharging: false)
            }
            if profile != autoTune.profile { profile = autoTune.profile }
            policy = autoTune.evaluate(sample)
            runtimeStatuses = supervisor.statuses()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func setProfile(_ newValue: TuneProfile) async {
        let applied = autoTune.setProfile(newValue, isCharging: metrics.isCharging)
        profile = applied
        policy = autoTune.evaluate(metrics)
    }

    func toggleServer() async {
        if serverRunning {
            await server.stop()
            logSocket.stop()
            serverRunning = false
            serverMessage = "Stopped"
        } else {
            do {
                try await server.start(port: 8080)
                try logSocket.start(port: 8081)
                serverRunning = true
                serverMessage = "REST :8080 · WebSocket :8081"
            } catch {
                serverRunning = server.isRunning
                serverMessage = "API error: \(error.localizedDescription)"
            }
        }
    }

    func runEditor(kind: RuntimeKind = .javascript) async -> RuntimeResult {
        supervisor.run(kind: kind, code: editorCode)
    }

    func runCommand(_ raw: String) async {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        appendTerminal("$ \(command)")

        if command == "help" {
            appendTerminal("help | runtimes | projects | kv keys | kv get <key> | kv set <key> <value> | js <code> | py <code> | lua <code> | api | status | clear")
        } else if command == "runtimes" {
            runtimeStatuses = supervisor.statuses()
            for item in runtimeStatuses {
                appendTerminal("\(item.id.rawValue): \(item.available ? "ready" : "not installed") — \(item.detail)")
            }
        } else if command == "projects" {
            for project in projects.list() {
                appendTerminal("\(project.id.prefix(8))  \(project.name)  \(project.runtime.rawValue)  \(project.state.rawValue)")
            }
        } else if command == "kv keys" {
            appendTerminal(store.keys().joined(separator: "\n"))
        } else if command.hasPrefix("kv get ") {
            let key = String(command.dropFirst(7))
            if let value = store.get(key), let text = String(data: value, encoding: .utf8) { appendTerminal(text) }
            else { appendTerminal("not found") }
        } else if command.hasPrefix("kv set ") {
            let rest = String(command.dropFirst(7))
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { appendTerminal("usage: kv set <key> <value>"); return }
            let data = Data(parts[1].utf8)
            store.set(parts[0], value: data)
            sqlite.set(parts[0], value: data)
            appendTerminal("stored")
        } else if command.hasPrefix("js ") {
            appendTerminal(supervisor.run(kind: .javascript, code: String(command.dropFirst(3))).output)
        } else if command.hasPrefix("py ") {
            appendTerminal(supervisor.run(kind: .python, code: String(command.dropFirst(3))).output)
        } else if command.hasPrefix("lua ") {
            appendTerminal(supervisor.run(kind: .lua, code: String(command.dropFirst(4))).output)
        } else if command == "api" {
            appendTerminal("REST: http://<iphone-ip>:8080/api/v1")
            appendTerminal("Logs WS: ws://<iphone-ip>:8081")
            appendTerminal("Authorization: Bearer \(apiKey)")
        } else if command == "status" {
            appendTerminal(String(format: "RAM %.1f MB | CPU %.1f%% | Thermal %@ | RPS %.2f", metrics.residentMemoryMB, metrics.cpuPercent, metrics.thermal, metrics.requestsPerSecond))
        } else if command == "clear" {
            terminalOutput = ""
        } else {
            appendTerminal("unknown command")
        }
    }

    private func appendTerminal(_ text: String) {
        terminalOutput += (terminalOutput.isEmpty ? "" : "\n") + text
    }
}
