import SwiftUI

struct RootView: View {
    @AppStorage("nexora.onboarding.completed") private var onboardingCompleted = false

    var body: some View {
        Group {
            if onboardingCompleted {
                mainTabs
            } else {
                NexoraOnboardingView(completed: $onboardingCompleted)
            }
        }
    }

    private var mainTabs: some View {
        TabView {
            ProjectsView()
                .tabItem { Label("Projects", systemImage: "folder") }

            AIView()
                .tabItem { Label("AI", systemImage: "sparkles") }

            NexoraActivityView()
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }

            NexoraIntegrationsView()
                .tabItem { Label("Integrations", systemImage: "point.3.connected.trianglepath.dotted") }

            NexoraSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct NexoraActivityView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Device") {
                    LabeledContent("Class", value: model.metrics.deviceClass)
                    LabeledContent("Thermal", value: model.metrics.thermal)
                    LabeledContent("Battery", value: "\(model.metrics.batteryPercent)%")
                    LabeledContent("Low Power Mode", value: model.metrics.lowPowerMode ? "On" : "Off")
                    LabeledContent("App RAM", value: String(format: "%.0f MB", model.metrics.residentMemoryMB))
                }

                Section("Projects") {
                    if model.localProjects.isEmpty {
                        Text("No local projects yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.localProjects) { project in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(project.name)
                                Text(project.runtime.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(project.state.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(project.state.rawValue == "running" ? .green : .secondary)
                        }
                    }
                }
            }
            .navigationTitle("Activity")
            .task { model.refreshLocalState() }
        }
    }
}

struct NexoraIntegrationsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Available") {
                    HStack {
                        Label("Local API", systemImage: "network")
                        Spacer()
                        Text(model.serverRunning ? "Running" : "Stopped")
                            .foregroundStyle(model.serverRunning ? .green : .secondary)
                    }

                    HStack {
                        Label("AI Provider", systemImage: "sparkles")
                        Spacer()
                        Text(model.ai.hasAPIKey ? model.ai.selectedProvider.name : "Optional")
                            .foregroundStyle(model.ai.hasAPIKey ? .green : .secondary)
                    }

                    NavigationLink {
                        NexoraWebhookView(projectID: nil)
                    } label: {
                        Label("Webhooks", systemImage: "link")
                    }

                    NavigationLink {
                        NexoraHistoryView(projectID: nil)
                    } label: {
                        Label("Activity History", systemImage: "clock.arrow.circlepath")
                    }

                    NavigationLink {
                        NexoraAPIExplorerView()
                    } label: {
                        Label("API Explorer", systemImage: "network")
                    }

                    Link(destination: NexoraConstants.supportDiscordURL) {
                        Label("Support Discord", systemImage: "bubble.left.and.bubble.right")
                    }
                }

                Section("Runtime reality") {
                    Text("Local automations and webhooks are implemented. Scheduled background execution remains best-effort because iOS may suspend Nexora.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Integrations")
        }
    }
}

struct NexoraSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Performance") {
                    Picker("Mode", selection: Binding(
                        get: { model.profile },
                        set: { value in Task { await model.setProfile(value) } }
                    )) {
                        ForEach(TuneProfile.allCases) { profile in
                            Text(profile.rawValue).tag(profile)
                        }
                    }

                    LabeledContent("Workers", value: "\(model.policy.workerLimit)")
                    LabeledContent("Runtime memory target", value: "\(model.policy.runtimeMemoryTargetMB) MB")
                    LabeledContent("Indexing", value: model.policy.indexingMode)
                    LabeledContent("Preview", value: "\(model.policy.previewFPS) FPS")
                    Text(model.policy.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Runtimes") {
                    NavigationLink("Capabilities") {
                        RuntimesView()
                    }
                    Text("Only runtimes that really execute in this IPA are marked Available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("AI Providers") {
                    NavigationLink(model.ai.hasAPIKey ? "\(model.ai.selectedProvider.name) settings" : "Connect AI Provider") {
                        AIView(showSettingsOnly: true)
                    }
                    Text("AI is optional. Local projects, files, runtimes and SQLite work without an AI key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("GitHub") {
                    NavigationLink("GitHub setup") {
                        NexoraGitHubSettingsView()
                    }
                    Text("A token is optional for public repositories and required for private repositories or pushing changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Storage & Recovery") {
                    NavigationLink("Storage") { NexoraStorageView() }
                    NavigationLink("History") { NexoraHistoryView(projectID: nil) }
                }

                Section("Notifications") {
                    Button("Enable Local Notifications") {
                        Task { _ = await NotificationService.shared.requestAuthorization() }
                    }
                    Text("Notifications are local and subject to iOS notification/background behavior.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Local API") {
                    LabeledContent("Status", value: model.serverRunning ? "Running" : "Stopped")
                    Button(model.serverRunning ? "Stop Local API" : "Start Local API") {
                        Task { await model.toggleServer() }
                    }
                    Text("The API runs on this Apple device. No Debian server or backend URL is required.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Support") {
                    Link(destination: NexoraConstants.supportDiscordURL) {
                        Label("Join Support Discord", systemImage: "bubble.left.and.bubble.right")
                    }
                    Text(NexoraConstants.supportDiscordURL.absoluteString)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
