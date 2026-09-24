import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 145), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        NexoraMetricCard(title: "Device", value: model.metrics.deviceClass)
                        NexoraMetricCard(title: "RAM", value: String(format: "%.0f MB", model.metrics.residentMemoryMB))
                        NexoraMetricCard(title: "CPU", value: String(format: "%.1f%%", model.metrics.cpuPercent))
                        NexoraMetricCard(title: "Thermal", value: model.metrics.thermal)
                        NexoraMetricCard(title: "Battery", value: "\(model.metrics.batteryPercent)%")
                        NexoraMetricCard(title: "Workers", value: "\(model.policy.workerLimit)")
                    }

                    GroupBox("Auto Tune") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.profile.rawValue)
                                .font(.headline)
                            Text(model.policy.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Memory target \(model.policy.runtimeMemoryTargetMB) MB · \(model.policy.indexingMode) indexing · \(model.policy.previewFPS) FPS preview")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Local API") {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(model.serverMessage)
                                Text("http://<device-ip>:8080/api/v1")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(model.serverRunning ? "Stop" : "Start") {
                                Task { await model.toggleServer() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Nexora Host")
        }
    }
}

private struct NexoraMetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
