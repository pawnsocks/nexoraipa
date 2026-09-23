import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var result = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextEditor(text: $model.editorCode)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Button("Run JavaScript") {
                        Task {
                            result = await model.runEditor().output
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
                ScrollView {
                    Text(result.isEmpty ? "Output appears here." : result)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 130)
            }
            .padding()
            .navigationTitle("Editor")
        }
    }
}
