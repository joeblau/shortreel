import SwiftUI

/// The prompt composer, pinned to the bottom of the inspector so it stays
/// reachable while the request history above scrolls.
struct DevicePromptView: View {
    let device: Device

    @Environment(DeviceManager.self) private var deviceManager
    @FocusState private var composerFocused: Bool

    var body: some View {
        @Bindable var session = deviceManager.promptSession(for: device)
        @Bindable var manager = deviceManager

        VStack(alignment: .leading, spacing: 10) {
            if let status = statusLine(session) {
                Label(status.text, systemImage: status.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .labelStyle(.titleAndIcon)
            }

            ZStack(alignment: .topLeading) {
                if session.draft.isEmpty {
                    Text("Open Safari, then scroll down")
                        .foregroundStyle(.tertiary)
                        .padding(9)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $session.draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .focused($composerFocused)
                    .accessibilityLabel("Instructions for \(device.name)")
            }
            .frame(height: 72)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }

            HStack(spacing: 10) {
                Menu("Try an example") {
                    ForEach(examples, id: \.self) { example in
                        Button(example) {
                            session.draft = example
                            composerFocused = true
                        }
                    }
                }
                .fixedSize()

                Picker("Planner", selection: $manager.visionProvider) {
                    ForEach(PhoneVisionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(deviceManager.isAnyPromptRunning)
                .help("Choose the planner for requests that use the phone’s screen.")

                Spacer()

                if session.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Button("Stop", role: .cancel) {
                        session.cancel()
                    }
                } else {
                    Button {
                        session.submit()
                    } label: {
                        HStack(spacing: 8) {
                            Text("Run")
                            Text("⌘ Enter")
                                .font(.caption)
                                .opacity(0.8)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Run instructions (Command-Enter)")
                    .disabled(!canSubmit(session))
                    .help("Run these instructions on \(device.name) (⌘ Enter)")
                }
            }
        }
        .padding(12)
    }

    private let examples = ["Open Safari", "Scroll down", "Go Home"]

    private func canSubmit(_ session: DevicePromptSession) -> Bool {
        device.isLive
            && session.unavailableReason == nil
            && !session.isRunning
            && !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One contextual status line instead of several stacked captions.
    private func statusLine(_ session: DevicePromptSession) -> (text: String, symbol: String)? {
        if session.isRunning {
            return ("Keep the iPhone unlocked and connected by USB and Bluetooth while the agent checks each step.", "info.circle")
        }
        if let reason = deviceManager.visionUnavailabilityReason {
            return (reason, "exclamationmark.triangle")
        }
        if !device.isLive {
            return ("Select an available iPhone to run instructions.", "info.circle")
        }
        if let reason = session.unavailableReason {
            return (reason, "info.circle")
        }
        return (deviceManager.visionProvider.screenRequestDescription, "lock.shield")
    }
}

/// The scrollable request history, shown above the pinned composer.
struct DevicePromptHistory: View {
    let device: Device

    @Environment(DeviceManager.self) private var deviceManager

    var body: some View {
        let session = deviceManager.promptSession(for: device)

        if !session.entries.isEmpty {
            Section("Requests") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(session.entries.reversed())) { entry in
                            requestRow(entry)
                            if entry.id != session.entries.first?.id {
                                Divider()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
                    .padding(.vertical, 2)
                }
                .frame(height: session.entries.contains(where: { !$0.steps.isEmpty }) ? 300 : min(230, CGFloat(session.entries.count) * 108))
            }
        }
    }

    private func requestRow(_ entry: DevicePromptEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.prompt)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(entry.status.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor(entry.status))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(statusColor(entry.status).opacity(0.1), in: Capsule())
                    .fixedSize()
            }

            if !entry.message.isEmpty {
                Text(entry.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !entry.steps.isEmpty {
                DisclosureGroup("\(entry.steps.count) steps") {
                    ForEach(entry.steps) { step in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(step.number). \(step.action)")
                                .font(.caption.weight(.medium))
                            Text(step.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func statusColor(_ status: DevicePromptStatus) -> Color {
        switch status {
        case .planning, .running: .accentColor
        case .sent, .cancelled: .secondary
        case .completed: .green
        case .failed, .needsInput: .orange
        }
    }
}
