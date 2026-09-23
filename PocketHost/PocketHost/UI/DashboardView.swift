import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        MetricCard(title: "RAM", value: String(format: "%.0f MB", model.metrics.residentMemoryMB))
                        MetricCard(title: "CPU", value: String(format: "%.1f%%", model.metrics.cpuPercent))
                        MetricCard(title: "Thermal", value: model.metrics.thermal)
                        MetricCard(title: "Battery", value: "\(model.metrics.batteryPercent)%\(model.metrics.isCharging ? " · Charging" : "")")
                        MetricCard(title: "RPS", value: String(format: "%.2f", model.metrics.requestsPerSecond))
                        MetricCard(title: "KV keys", value: "\(model.metrics.keyValueCount)")
                    }

                    GroupBox("Local API") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.serverMessage).font(.subheadline)
                                    Text("http://<iphone-ip>:8080/api/v1")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(model.serverRunning ? "Stop" : "Start") {
                                    Task { await model.toggleServer() }
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            Divider()
                            Text("Bearer token")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(model.apiKey)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                            Text("All protected /api/v1 endpoints require Authorization: Bearer <token>.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    GroupBox("Auto-Tune") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Profile", selection: Binding(
                                get: { model.profile },
                                set: { value in Task { await model.setProfile(value) } }
                            )) {
                                ForEach(TuneProfile.allCases) { profile in Text(profile.rawValue).tag(profile) }
                            }
                            .pickerStyle(.segmented)
                            Text("Workers \(model.policy.workerLimit) · Cache \(model.policy.cacheLimitMB) MB · Tick \(model.policy.tickIntervalMS) ms")
                                .font(.subheadline)
                            Text(model.policy.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("PocketHost")
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
