import SwiftUI

struct AIView: View {
    @EnvironmentObject private var model: AppModel
    @State private var apiKey = ""
    @State private var models: [AIModel] = []
    @State private var selectedModel = ""
    @State private var prompt = ""
    @State private var answer = ""
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("NanoGPT") {
                    SecureField(model.ai.config().maskedAPIKey ?? "API key", text: $apiKey)
                    Button("Save API key") {
                        do {
                            _ = try model.ai.update(.init(apiKey: apiKey, selectedModel: nil, baseURL: nil))
                            apiKey = ""
                            status = "API key saved in Keychain"
                        } catch { status = error.localizedDescription }
                    }
                    Text("https://nano-gpt.com/api/v1").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Section("Model") {
                    Picker("Model", selection: $selectedModel) {
                        if selectedModel.isEmpty { Text("Select model").tag("") }
                        ForEach(models) { item in Text(item.id).tag(item.id) }
                    }
                    .onChange(of: selectedModel) { value in
                        guard !value.isEmpty else { return }
                        _ = try? model.ai.update(.init(apiKey: nil, selectedModel: value, baseURL: nil))
                    }
                    Button("Load models") { Task { await loadModels() } }
                }
                Section("Chat") {
                    TextEditor(text: $prompt).frame(minHeight: 120)
                    Button(busy ? "Sending…" : "Send") { Task { await send() } }.disabled(busy || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedModel.isEmpty)
                    if !answer.isEmpty { Text(answer).textSelection(.enabled) }
                }
                if !status.isEmpty { Section { Text(status).font(.caption).foregroundStyle(.secondary) } }
            }
            .navigationTitle("AI")
            .task {
                selectedModel = model.ai.selectedModel ?? ""
                if model.ai.hasAPIKey { await loadModels() }
            }
        }
    }

    private func loadModels() async {
        busy = true; defer { busy = false }
        do {
            models = try await model.ai.listModels()
            if selectedModel.isEmpty, let first = models.first?.id { selectedModel = first }
            status = "Loaded \(models.count) models"
        } catch { status = error.localizedDescription }
    }

    private func send() async {
        busy = true; defer { busy = false }
        do {
            _ = try model.ai.update(.init(apiKey: nil, selectedModel: selectedModel, baseURL: nil))
            let response = try await model.ai.chat(.init(model: selectedModel, messages: [.init(role: "user", content: prompt)], temperature: nil))
            answer = response.message.content
            status = response.model
        } catch { status = error.localizedDescription }
    }
}
