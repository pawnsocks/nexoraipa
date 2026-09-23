import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            ProjectsView()
                .tabItem { Label("Projects", systemImage: "folder") }

            AIView()
                .tabItem { Label("AI", systemImage: "sparkles") }

            NexoraHostingView()
                .tabItem { Label("Hosting", systemImage: "server.rack") }

            NexoraActivityView()
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }

            NexoraSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct NexoraHostingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var message = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Backend") {
                    HStack {
                        Circle()
                            .fill(model.backendConnected ? Color.green : Color.orange)
                            .frame(width: 10, height: 10)
                        Text(model.backendStatus)
                        Spacer()
                    }
                }

                Section("Running processes") {
                    if model.remoteProcesses.isEmpty {
                        Text(model.remote.isConfigured ? "No remote processes are running." : "Configure the backend first.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(model.remoteProcesses) { process in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(process.projectName)
                                        .font(.headline)
                                    Text(process.command)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Text(process.status.uppercased())
                                    .font(.caption2.bold())
                                    .foregroundStyle(process.status == "running" ? .green : .secondary)
                            }

                            HStack(spacing: 16) {
                                if let port = process.port { Label("\(port)", systemImage: "network") }
                                if let memory = process.memoryMB { Label(String(format: "%.0f MB", memory), systemImage: "memorychip") }
                                Label(formatUptime(process.uptimeSeconds), systemImage: "clock")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            if let url = process.previewURL, let target = URL(string: url) {
                                Link("Open preview", destination: target)
                                    .font(.caption)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !message.isEmpty {
                    Section("Status") {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Hosting")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        do {
            model.remoteProcesses = try await model.remote.listProcesses()
            message = "Updated"
        } catch {
            message = error.localizedDescription
        }
    }

    private func formatUptime(_ seconds: Double) -> String {
        let value = Int(seconds)
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

struct NexoraActivityView: View {
    @EnvironmentObject private var model: AppModel
    @State private var status = ""

    var body: some View {
        NavigationStack {
            List {
                if model.remoteActivities.isEmpty {
                    Text(model.remote.isConfigured ? "No recent backend tasks." : "Configure the backend in Settings.")
                        .foregroundStyle(.secondary)
                }

                ForEach(model.remoteActivities) { task in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(task.kind.capitalized)
                                .font(.headline)
                            Spacer()
                            Text(task.status.uppercased())
                                .font(.caption2.bold())
                                .foregroundStyle(statusColor(task.status))
                        }
                        if let command = task.command, !command.isEmpty {
                            Text(command)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if let step = task.currentStep, !step.isEmpty {
                            Label(step, systemImage: "arrow.right.circle")
                                .font(.caption)
                        }
                        if !task.output.isEmpty {
                            Text(task.output)
                                .font(.caption.monospaced())
                                .lineLimit(4)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        do {
            model.remoteActivities = try await model.remote.listTasks()
            status = ""
        } catch {
            status = error.localizedDescription
        }
    }

    private func statusColor(_ value: String) -> Color {
        switch value {
        case "running", "queued": return .blue
        case "completed": return .green
        case "failed": return .red
        case "cancelled": return .orange
        default: return .secondary
        }
    }
}

struct NexoraSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var backendURL = ""
    @State private var ownerToken = ""
    @State private var nanoKey = ""
    @State private var status = ""
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Nexora Host backend") {
                    TextField("https://dev.example.com", text: $backendURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    SecureField(model.remote.maskedToken ?? "Owner token", text: $ownerToken)
                        .textInputAutocapitalization(.never)

                    Button("Save backend") {
                        do {
                            try model.remote.configure(baseURL: backendURL, ownerToken: ownerToken.isEmpty ? nil : ownerToken)
                            ownerToken = ""
                            status = "Backend saved"
                            Task { await testBackend() }
                        } catch {
                            status = error.localizedDescription
                        }
                    }

                    Button(testing ? "Testing…" : "Test connection") {
                        Task { await testBackend() }
                    }
                    .disabled(testing)

                    Text(model.backendStatus)
                        .font(.caption)
                        .foregroundStyle(model.backendConnected ? .green : .secondary)
                }

                Section("NanoGPT") {
                    SecureField(model.ai.maskedAPIKey ?? "NanoGPT API key", text: $nanoKey)
                        .textInputAutocapitalization(.never)

                    Button("Save NanoGPT key") {
                        do {
                            _ = try model.ai.update(.init(apiKey: nanoKey, selectedModel: nil, baseURL: nil))
                            nanoKey = ""
                            status = "NanoGPT key saved in Keychain"
                        } catch {
                            status = error.localizedDescription
                        }
                    }

                    NavigationLink("Model browser") {
                        AIView(showSettingsOnly: true)
                    }
                }

                Section("Runtimes") {
                    NavigationLink("Runtime catalog") {
                        RuntimesView()
                    }
                    Text("Project runtimes run on the Debian backend. The iPhone stays the controller/editor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Security") {
                    Text("One owner only. Backend requests use the owner token. NanoGPT and backend secrets stay in the iOS Keychain. Nexora Host does not include plans, billing, public registration, teams or customer management.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !status.isEmpty {
                    Section("Status") {
                        Text(status)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                backendURL = model.remote.baseURL
            }
        }
    }

    private func testBackend() async {
        testing = true
        defer { testing = false }
        do {
            let health = try await model.remote.health()
            model.backendConnected = health.ok
            model.backendStatus = health.ok ? "Connected · \(health.hostname ?? "backend")" : "Backend unavailable"
            status = model.backendStatus
            await model.refreshRemoteOverview()
        } catch {
            model.backendConnected = false
            model.backendStatus = error.localizedDescription
            status = error.localizedDescription
        }
    }
}
