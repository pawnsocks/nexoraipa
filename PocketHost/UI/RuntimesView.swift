import SwiftUI

struct RuntimesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List(model.runtimeStatuses) { runtime in
                HStack(spacing: 12) {
                    Image(systemName: runtime.available ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(runtime.available ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(runtime.id.rawValue).font(.headline)
                        Text(runtime.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Runtimes")
        }
    }
}
