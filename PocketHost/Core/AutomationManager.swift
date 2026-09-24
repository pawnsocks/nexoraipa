import Foundation

struct NexoraAutomation: Identifiable, Codable, Sendable, Equatable {
    enum Trigger: String, Codable, Sendable, CaseIterable, Identifiable {
        case manual = "Manual"
        case runCompleted = "Run Completed"
        case runFailed = "Run Failed"
        case projectStarted = "Project Started"
        var id: String { rawValue }
    }

    enum Action: String, Codable, Sendable, CaseIterable, Identifiable {
        case createBackup = "Create Backup"
        case sendWebhook = "Send Webhook"
        var id: String { rawValue }
    }

    let id: String
    var projectID: String
    var name: String
    var trigger: Trigger
    var action: Action
    var webhookID: String?
    var enabled: Bool
}

final class AutomationManager: @unchecked Sendable {
    private let defaults = UserDefaults.standard
    private let backups: BackupManager
    private let webhooks: WebhookManager
    private let history: HistoryStore

    init(backups: BackupManager, webhooks: WebhookManager, history: HistoryStore) {
        self.backups = backups
        self.webhooks = webhooks
        self.history = history
    }

    func list(projectID: String? = nil) -> [NexoraAutomation] {
        let all = load()
        return projectID.map { id in all.filter { $0.projectID == id } } ?? all
    }

    func save(_ automation: NexoraAutomation) {
        var all = load()
        if let index = all.firstIndex(where: { $0.id == automation.id }) { all[index] = automation }
        else { all.append(automation) }
        persist(all)
    }

    func delete(_ id: String) {
        var all = load()
        all.removeAll { $0.id == id }
        persist(all)
    }

    func fire(trigger: NexoraAutomation.Trigger, projectID: String, variables: [String: String] = [:]) async {
        let candidates = list(projectID: projectID).filter { $0.enabled && $0.trigger == trigger }
        for automation in candidates {
            do {
                switch automation.action {
                case .createBackup:
                    _ = try backups.create(projectID: projectID, label: "Automation: \(automation.name)")
                case .sendWebhook:
                    guard let webhookID = automation.webhookID else { continue }
                    _ = try await webhooks.send(webhookID: webhookID, variables: variables)
                }
                history.append(projectID: projectID, kind: .automation, title: "Automation completed", detail: automation.name)
            } catch {
                history.append(projectID: projectID, kind: .automation, title: "Automation failed", detail: "\(automation.name): \(error.localizedDescription)")
            }
        }
    }

    private func load() -> [NexoraAutomation] {
        guard let data = defaults.data(forKey: "nexora.automations"), let value = try? JSONDecoder().decode([NexoraAutomation].self, from: data) else { return [] }
        return value
    }

    private func persist(_ value: [NexoraAutomation]) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "nexora.automations") }
    }
}
