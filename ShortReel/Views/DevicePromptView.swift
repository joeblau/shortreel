import SwiftUI

struct DevicePromptView: View {
    let device: Device

    @Environment(DeviceManager.self) private var deviceManager
    @FocusState private var composerFocused: Bool

    var body: some View {
        @Bindable var session = deviceManager.promptSession(for: device)
        @Bindable var manager = deviceManager

        Section("Ask this iPhone") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Planner", selection: $manager.visionProvider) {
                    ForEach(PhoneVisionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .disabled(deviceManager.isAnyPromptRunning)
                .help("Choose the planner for requests that use the phone’s screen.")

                Text(deviceManager.visionProvider.screenRequestDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let reason = deviceManager.visionUnavailabilityReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(session.canUseScreen
                    ? "Run a command, or ask the agent to use the screen."
                    : "Give your iPhone a command over Bluetooth.")
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    if session.draft.isEmpty {
                        Text("Open Safari, then scroll down")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $session.draft)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .focused($composerFocused)
                        .accessibilityLabel("Instructions for \(device.name)")
                }
                .frame(height: 84)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }

                HStack {
                    Menu("Try an example") {
                        ForEach(examples, id: \.self) { example in
                            Button(example) {
                                session.draft = example
                                composerFocused = true
                            }
                        }
                    }
                    .fixedSize()

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

                if let connectionHint {
                    Label(connectionHint, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(session.canUseScreen
                        ? "Keep the iPhone unlocked and connected by USB and Bluetooth while the agent checks each step."
                        : "Bluetooth commands are ready. Add the USB screen for requests that need to see buttons or read the phone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }

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

    private let examples = ["Open Safari", "Scroll down", "Go Home"]

    private func canSubmit(_ session: DevicePromptSession) -> Bool {
        device.isLive
            && session.unavailableReason == nil
            && !session.isRunning
            && !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var connectionHint: String? {
        if !device.isLive {
            return "Select an available iPhone to run instructions."
        }
        return deviceManager.promptSession(for: device).unavailableReason
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
