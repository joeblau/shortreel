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

        VStack(alignment: .leading, spacing: 8) {
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
                        .padding(8)
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

            // One tier per control: examples are tertiary, the planner is
            // secondary, and Run is the only prominent button.
            HStack(spacing: 8) {
                Menu {
                    ForEach(examples, id: \.self) { example in
                        Button(example) {
                            session.draft = example
                            composerFocused = true
                        }
                    }
                } label: {
                    Label("Try an example", systemImage: "lightbulb")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Try an example")

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
                    Button("Run") {
                        session.submit()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Run instructions (Command-Enter)")
                    .disabled(!canSubmit(session))
                    .help("Run these instructions on \(device.name) (⌘↩)")
                }
            }
        }
        .padding(16)
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
        return nil
    }
}

/// The request history: one plain scrolling list, newest first. Rows are
/// grouped by whitespace rather than cards or separators, and each leads
/// with a status glyph so the list scans by shape before text.
struct DevicePromptHistory: View {
    let device: Device

    @Environment(DeviceManager.self) private var deviceManager

    var body: some View {
        let session = deviceManager.promptSession(for: device)

        if session.entries.isEmpty {
            ContentUnavailableView {
                Label("No Requests", systemImage: "text.bubble")
            } description: {
                Text("Instructions you run on \(device.name) appear here.")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(session.entries.reversed()) { entry in
                        requestRow(entry)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func requestRow(_ entry: DevicePromptEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            statusGlyph(entry.status)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.prompt)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)

                Text(entry.message.isEmpty ? entry.status.displayName : entry.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !entry.steps.isEmpty {
                    DisclosureGroup("\(entry.steps.count) steps") {
                        ForEach(entry.steps) { step in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(step.number). \(step.action)")
                                    .font(.caption.weight(.medium))
                                Text(step.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                    }
                    .font(.callout)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func statusGlyph(_ status: DevicePromptStatus) -> some View {
        Group {
            if status.isActive {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: statusSymbol(status))
                    .foregroundStyle(statusColor(status))
            }
        }
        .help(status.displayName)
        .accessibilityLabel(status.displayName)
    }

    private func statusSymbol(_ status: DevicePromptStatus) -> String {
        switch status {
        case .planning, .running: "circle.dotted"
        case .sent: "paperplane.circle.fill"
        case .cancelled: "stop.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .needsInput: "questionmark.circle.fill"
        }
    }

    // Red is reserved for a failure — the one moment it should read as a
    // signal — so it stays quiet across the rest of the list.
    private func statusColor(_ status: DevicePromptStatus) -> Color {
        switch status {
        case .planning, .running: .accentColor
        case .sent, .cancelled: .secondary
        case .completed: .green
        case .failed: .red
        case .needsInput: .orange
        }
    }
}
