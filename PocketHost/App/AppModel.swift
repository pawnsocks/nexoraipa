import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var metrics = MetricsSnapshot()
    @Published var policy = TunedPolicy(
        workerLimit: 2,
        cacheLimitMB: 64,
        tickIntervalMS: 500,
        suspendIdleRuntimes: true,
        note: "Auto Tune starting"
    )
    @Published var profile: TuneProfile = .auto
    @Published var serverRunning = false
    @Published var serverMessage = "Stopped"
    @Published var runtimeStatuses: [RuntimeStatus] = []
    @Published var localProjects: [ProjectRecord] = []
    @Published var terminalOutput = "Nexora Host local console\nType help for commands."
    @Published var editorCode = "console.log('Hello from Nexora Host');"

    let store = KeyValueStore()
    let sqlite = SQLiteStore()
    let metricsBox = MetricsBox()
    let autoTune = AutoTuneEngine()
    let apiKeyStore = APIKeyStore()
    let logs = LogBroker()
    let packs = RuntimePackManager()
    let ai = AIProviderService()
    let github = GitHubService()
    let history = HistoryStore()

    lazy var backups = BackupManager(projects: projects, history: history)
    lazy var archives = ArchiveManager()
    lazy var webhooks = WebhookManager(history: history)
    lazy var automations = AutomationManager(backups: backups, webhooks: webhooks, history: history)

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
        refreshLocalState()

        do {
            try await server.start(port: 8080)
            try logSocket.start(port: 8081)
            serverRunning = true
            serverMessage = "Local API :8080 · Logs :8081"
        } catch {
            serverRunning = server.isRunning
            serverMessage = server.isRunning ? "Local API running" : "Local API unavailable"
        }

        while !Task.isCancelled {
            let sample = sampler.sample(
                requestsPerSecond: server.requestCounter.rps(),
                keyValueCount: store.count
            )
            metrics = sample
            metricsBox.set(sample)
            policy = autoTune.evaluate(sample)
            profile = autoTune.profile
            runtimeStatuses = supervisor.statuses()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func refreshLocalState() {
        localProjects = projects.list()
        runtimeStatuses = supervisor.statuses()
    }

    func setProfile(_ value: TuneProfile) async {
        profile = autoTune.setProfile(value, isCharging: metrics.isCharging)
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
                serverMessage = "Local API :8080 · Logs :8081"
            } catch {
                serverRunning = server.isRunning
                serverMessage = "Local API error: \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func runProject(_ id: String) -> RuntimeResult {
        do {
            let (project, source) = try projects.entrypointSource(id)
            let result = supervisor.startProject(projectID: id, kind: project.runtime, code: source)
            _ = try projects.setState(id, result.succeeded ? .running : .error)
            history.append(
                projectID: id,
                kind: result.succeeded ? .projectRun : .runtimeFailed,
                title: result.succeeded ? "Project started" : "Run failed",
                detail: result.output
            )
            if result.succeeded {
                NotificationService.shared.send(title: "Nexora Host", body: "\(project.name) started locally.", projectID: id)
                Task { await automations.fire(trigger: .projectStarted, projectID: id, variables: ["project.name": project.name, "runtime.status": "running"]) }
            } else {
                NotificationService.shared.send(title: "Nexora Host", body: "\(project.name) failed to run.", projectID: id)
                Task { await automations.fire(trigger: .runFailed, projectID: id, variables: ["project.name": project.name, "runtime.status": "failed", "error.message": result.output]) }
            }
            refreshLocalState()
            return result
        } catch {
            let result = RuntimeResult(output: "Run failed: \(error)", succeeded: false)
            _ = try? projects.setState(id, .error)
            logs.append(projectID: id, level: "error", result.output)
            history.append(projectID: id, kind: .runtimeFailed, title: "Run failed", detail: result.output)
            if let project = projects.get(id) {
                NotificationService.shared.send(title: "Nexora Host", body: "\(project.name) failed to run.", projectID: id)
                Task { await automations.fire(trigger: .runFailed, projectID: id, variables: ["project.name": project.name, "runtime.status": "failed", "error.message": result.output]) }
            }
            refreshLocalState()
            return result
        }
    }

    func stopProject(_ id: String) {
        supervisor.stopProject(projectID: id)
        _ = try? projects.setState(id, .stopped)
        history.append(projectID: id, kind: .projectRun, title: "Project stopped")
        refreshLocalState()
    }

    @discardableResult
    func restartProject(_ id: String) -> RuntimeResult {
        stopProject(id)
        return runProject(id)
    }

    func runEditor(kind: RuntimeKind = .javascript, code: String? = nil) async -> RuntimeResult {
        supervisor.run(kind: kind, code: code ?? editorCode)
    }

    func runCommand(_ raw: String) async {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        appendTerminal("$ \(command)")

        if command == "help" {
            appendTerminal("help | runtimes | projects | js <code> | py <code> | lua <code> | status | api | clear")
        } else if command == "runtimes" {
            runtimeStatuses = supervisor.statuses()
            for runtime in runtimeStatuses {
                appendTerminal("\(runtime.id.rawValue): \(runtime.available ? "available" : "unavailable") — \(runtime.detail)")
            }
        } else if command == "projects" {
            refreshLocalState()
            for project in localProjects {
                appendTerminal("\(project.id.prefix(8))  \(project.name)  \(project.runtime.rawValue)  \(project.state.rawValue)")
            }
        } else if command.hasPrefix("js ") {
            appendTerminal(supervisor.run(kind: .javascript, code: String(command.dropFirst(3))).output)
        } else if command.hasPrefix("py ") {
            appendTerminal(supervisor.run(kind: .python, code: String(command.dropFirst(3))).output)
        } else if command.hasPrefix("lua ") {
            appendTerminal(supervisor.run(kind: .lua, code: String(command.dropFirst(4))).output)
        } else if command == "status" {
            appendTerminal(String(
                format: "RAM %.1f MB | CPU %.1f%% | Thermal %@ | Battery %d%%",
                metrics.residentMemoryMB,
                metrics.cpuPercent,
                metrics.thermal,
                metrics.batteryPercent
            ))
        } else if command == "api" {
            appendTerminal("REST: http://<device-ip>:8080/api/v1")
            appendTerminal("Logs: ws://<device-ip>:8081")
        } else if command == "clear" {
            terminalOutput = ""
        } else {
            appendTerminal("Unsupported local command. Nexora does not expose a fake desktop shell.")
        }
    }

    private func appendTerminal(_ text: String) {
        terminalOutput += (terminalOutput.isEmpty ? "" : "\n") + text
    }
}
