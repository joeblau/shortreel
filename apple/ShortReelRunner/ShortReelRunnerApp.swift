import SwiftUI

@main
struct ShortReelRunnerApp: App {
    var body: some Scene {
        WindowGroup {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 8) {
                    Text("ShortReelRunner")
                        .font(.headline)
                    Text(Bundle.main.bundleIdentifier ?? "unknown")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }
        }
    }
}
