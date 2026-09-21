import SwiftUI

/// Stub host app. Its only job is to carry the ShortReelRunnerUITests bundle;
/// the driver lives in the test process, not here.
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
