import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Home", systemImage: "gauge.with.dots.needle.67percent") }
            ProjectsView()
                .tabItem { Label("Projects", systemImage: "square.stack.3d.up") }
            RuntimesView()
                .tabItem { Label("Runtimes", systemImage: "shippingbox") }
            EditorView()
                .tabItem { Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right") }
            AIView()
                .tabItem { Label("AI", systemImage: "sparkles") }
            TerminalView()
                .tabItem { Label("Terminal", systemImage: "terminal") }
        }
    }
}
