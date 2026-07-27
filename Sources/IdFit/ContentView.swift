import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("ID Fit")
                .font(.largeTitle.bold())
            Text("Open a folder with document scans to get started.")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview {
    ContentView()
}
