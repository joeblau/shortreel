import SwiftUI

struct PersonalityEditor: View {
    @Binding var brief: String
    @Binding var narrative: String
    let network: Platform

    @Environment(DeviceManager.self) private var deviceManager
    @State private var requestID: UUID?
    @State private var generationError: String?

    private var isGenerating: Bool { requestID != nil }
    private var limitedBrief: Binding<String> {
        Binding(get: { brief }, set: {
            brief = String($0.prefix(PersonalityGenerator.maximumBriefLength))
            generationError = nil
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Personality")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isGenerating {
                    ProgressView().controlSize(.mini)
                    Button("Cancel") { requestID = nil }
                        .controlSize(.small)
                } else {
                    Button("Generate", systemImage: "sparkles") {
                        generationError = nil
                        requestID = UUID()
                    }
                    .controlSize(.small)
                    .disabled(brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Text("Describe their interests, voice, and goals in up to 160 characters.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("A few details to build on…", text: limitedBrief, axis: .vertical)
                .lineLimit(2...4)
                .accessibilityLabel("Personality prompt")
                .disabled(isGenerating)
            Text("\(brief.count)/\(PersonalityGenerator.maximumBriefLength)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("\(brief.count) of 160 characters")

            if let generationError {
                Text(generationError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !narrative.isEmpty {
                TextField("Personality", text: $narrative, axis: .vertical)
                    .lineLimit(4...12)
                    .accessibilityLabel("Generated personality")
                    .disabled(isGenerating)
            }
        }
        .textFieldStyle(.roundedBorder)
        .task(id: requestID) {
            guard let id = requestID else { return }
            let provider: PhoneVisionProvider
            switch deviceManager.visionProvider {
            case .claude, .codex: provider = deviceManager.visionProvider
            case .uiTars, .onDevice: provider = ClaudePhonePlanner.isInstalled ? .claude : .codex
            }
            let model = provider == deviceManager.visionProvider
                ? deviceManager.visionModel : (provider.defaultModel ?? "")
            do {
                let result = try await PersonalityGenerator.generate(brief: brief, network: network.displayName) { prompt, instructions, schema in
                    switch provider {
                    case .claude:
                        return try await ClaudePhonePlanner.textResponse(prompt: prompt, instructions: instructions, schema: schema, model: model)
                    case .codex:
                        return try await CodexPhonePlanner.textResponse(prompt: prompt, instructions: instructions, schema: schema, model: model)
                    case .uiTars, .onDevice:
                        throw PersonalityGenerator.GenerationError.invalidResponse
                    }
                }
                guard !Task.isCancelled, requestID == id else { return }
                narrative = result
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                generationError = error.localizedDescription
            }
            if requestID == id { requestID = nil }
        }
        .onChange(of: network) { _, _ in requestID = nil }
        .onDisappear { requestID = nil }
    }
}
