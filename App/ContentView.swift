import SwiftUI
import Chat
import Core

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Super")
                .font(.system(size: 36, weight: .regular, design: .serif))
                .italic()
            Text("Chat MVP scaffolding")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Core v\(Core.version) · Chat v\(Chat.version)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
