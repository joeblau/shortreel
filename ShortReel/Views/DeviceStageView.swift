import SwiftUI

/// The pipeline stages for the selected phone, shown by the inspector's
/// Stage segment. Ordering matters: a clean home screen, then warm-up, then
/// content creation. Rows match the request history: plain, whitespace-grouped.
struct DeviceStageView: View {
    let device: Device

    private static let stages = ["Clear Home Screen", "Warm Up", "Create Content"]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.stages.enumerated()), id: \.offset) { index, name in
                    Label(name, systemImage: "\(index + 1).circle")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
    }
}
