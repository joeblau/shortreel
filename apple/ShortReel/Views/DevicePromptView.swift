import SwiftUI

/// The message composer, pinned to the bottom of the inspector so it stays
/// reachable while the transcript above scrolls. Return sends; Option-Return
/// inserts a newline.
struct DevicePromptView: View {
    let device: Device

    @Environment(DeviceManager.self) private var deviceManager
    @FocusState private var composerFocused: Bool

    var body: some View {
        @Bindable var session = deviceManager.promptSession(for: device)

        VStack(alignment: .leading, spacing: 8) {
            DeviceRunQueueView(session: session)
            // Say why a message cannot be sent, or why the planner will not
            // see the screen, instead of silently disabling the button.
            if let notice = notice(session) {
                Label(notice.text, systemImage: notice.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("composer-notice")
            }

            HStack(alignment: .bottom, spacing: 4) {
                TextField("Message \(device.name)", text: $session.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .font(.body)
                    .focused($composerFocused)
                    .onSubmit {
                        guard canSubmit(session) else { return }
                        deviceManager.prepareVisionProvider()
                        session.submit()
                    }
                    .padding(.leading, 12)
                    .padding(.vertical, 8)
                    .accessibilityLabel("Message for \(device.name)")

                sendButton(session)
                    .padding(4)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
        }
        .padding(16)
    }

    /// Round send button inside the field; becomes Stop while a run is active.
    @ViewBuilder
    private func sendButton(_ session: DevicePromptSession) -> some View {
        if session.isRunning {
            Button {
                session.cancel()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.red, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .accessibilityLabel("Stop")
            .help("Stop (⌘.)")
        } else {
            let enabled = canSubmit(session)
            Button {
                deviceManager.prepareVisionProvider()
                session.submit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(enabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!enabled)
            .accessibilityLabel("Send")
            .help("Send to \(device.name) (Return)")
        }
    }

    private func notice(_ session: DevicePromptSession) -> (text: String, symbol: String)? {
        if session.isRunning { return nil }
        if !device.isLive { return ("This iPhone is no longer available.", "exclamationmark.triangle") }
        if let reason = session.unavailableReason { return (reason, "exclamationmark.triangle") }
        if let reason = deviceManager.visionUnavailabilityReason { return (reason, "eye.slash") }
        return nil
    }

    private func canSubmit(_ session: DevicePromptSession) -> Bool {
        device.isLive
            && session.unavailableReason == nil
            && !session.isRunning
            && !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The transcript, oldest first. Each request is an outgoing bubble followed
/// by the agent's incoming bubbles: what it saw, what it did, and how it
/// ended — with a typing indicator while it is still working.
struct DevicePromptHistory: View {
    let device: Device

    @Environment(DeviceManager.self) private var deviceManager

    var body: some View {
        let session = deviceManager.promptSession(for: device)

        if session.entries.isEmpty {
            ContentUnavailableView {
                Label("No Messages", systemImage: "text.bubble")
            } description: {
                Text("Tell \(device.name) what to do, like “Open Safari”.")
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(session.entries) { entry in
                            ChatTranscriptEntry(entry: entry)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(16)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: transcriptRevision(session)) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    /// Changes whenever a bubble is added or the last one changes, so the
    /// transcript follows the conversation like Messages does.
    private func transcriptRevision(_ session: DevicePromptSession) -> Int {
        guard let last = session.entries.last else { return 0 }
        var hasher = Hasher()
        hasher.combine(session.entries.count)
        hasher.combine(last.steps.count)
        hasher.combine(last.sentActions.count)
        hasher.combine(last.status)
        hasher.combine(last.message)
        return hasher.finalize()
    }
}

private struct ChatTranscriptEntry: View {
    let entry: DevicePromptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ChatBubble(.outgoing) {
                if let workflow = entry.workflow {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.scriptTitle ?? workflow.title)
                        DisclosureGroup("Task details") { Text(entry.prompt).font(.caption) }
                    }
                } else {
                    Text(entry.prompt)
                }
            }

            ForEach(entry.steps) { step in
                if !step.detail.isEmpty {
                    ChatBubble(.incoming) {
                        Text(step.detail)
                    }
                }
                ChatBubble(.incoming) {
                    Text(Self.actionLabel(step.action))
                }
                .help(step.action)
            }

            ForEach(Array(entry.sentActions.enumerated()), id: \.offset) { _, action in
                ChatBubble(.incoming) {
                    Text(Self.actionLabel(action))
                }
                .help(action)
            }

            if entry.status.isActive {
                ChatBubble(.incoming) {
                    TypingIndicator()
                }
                if !entry.message.isEmpty {
                    caption(entry.message, color: .secondary)
                }
            } else {
                if !entry.message.isEmpty {
                    ChatBubble(.incoming) {
                        Text(entry.message)
                    }
                }
                caption(entry.status.displayName, color: statusColor(entry.status))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.leading, 12)
            .padding(.top, 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // Red only for a failure — the one moment it should read as a signal.
    private func statusColor(_ status: DevicePromptStatus) -> Color {
        switch status {
        case .planning, .running: .accentColor
        case .queued: .secondary
        case .cancelled, .completed: .secondary
        case .failed: .red
        case .needsInput, .needsReview: .orange
        }
    }

    /// Emoji + verb for an action bubble; the full action stays in the tooltip.
    static func actionLabel(_ action: String) -> String {
        let lower = action.lowercased()
        if lower.hasPrefix("go home") || lower == "home" { return "🏠 Home" }
        if lower.hasPrefix("double tap") { return "👆👆 Double Tap" }
        if lower.hasPrefix("tap") { return "👆 Tap" }
        if lower.hasPrefix("swipe") { return "👉 \(action)" }
        if lower.hasPrefix("drag") { return "👉 Drag" }
        if lower.hasPrefix("type") { return "⌨️ Type" }
        if lower.hasPrefix("press") { return "⌨️ \(action)" }
        if lower.hasPrefix("open") { return "📱 \(action)" }
        if lower.hasPrefix("search") { return "🔍 \(action)" }
        if lower.hasPrefix("wait") { return "⏳ Wait" }
        return action
    }
}

private enum ChatBubbleRole {
    case outgoing, incoming
}

/// A Messages-style bubble: accent-filled on the right for the user,
/// neutral on the left for the agent.
private struct ChatBubble<Content: View>: View {
    let role: ChatBubbleRole
    @ViewBuilder let content: Content

    init(_ role: ChatBubbleRole, @ViewBuilder content: () -> Content) {
        self.role = role
        self.content = content()
    }

    private var alignment: Alignment { role == .outgoing ? .trailing : .leading }

    var body: some View {
        content
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(role == .outgoing ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(
                role == .outgoing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .frame(maxWidth: 300, alignment: alignment)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

/// Three dots that pulse in sequence while the agent is thinking or acting.
private struct TypingIndicator: View {
    var body: some View {
        // Reserve a message line's height; the symbol alone is only dot-height.
        Text("…")
            .font(.body)
            .hidden()
            .frame(minWidth: 24)
            .overlay {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers.reversing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Working")
    }
}

/// Picks the model client or an installed CLI planner. Lives in the inspector
/// header, since it applies to every phone. Planners with a model choice are
/// submenus holding their own models, so every planner's model is visible
/// and choosing one selects that planner in the same click.
struct PlannerMenu: View {
    @Environment(DeviceManager.self) private var deviceManager
    @State private var editingModel = false
    @State private var editingProvider: PhoneVisionProvider = .defaultProvider
    @State private var modelDraft = ""

    var body: some View {
        Menu {
            ForEach(deviceManager.availableVisionProviders) { provider in
                if provider.defaultModel != nil {
                    Menu {
                        Picker("Model", selection: modelSelection(for: provider)) {
                            ForEach(provider.modelChoices, id: \.self) { model in
                                Text(model).tag(model)
                            }
                            let current = deviceManager.visionModel(for: provider)
                            if !provider.modelChoices.contains(current) {
                                Text(current).tag(current)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        Divider()
                        Button("Custom Model…") {
                            editingProvider = provider
                            modelDraft = deviceManager.visionModel(for: provider)
                            editingModel = true
                        }
                    } label: {
                        providerLabel(provider)
                    }
                } else {
                    Button {
                        deviceManager.visionProvider = provider
                    } label: {
                        providerLabel(provider)
                    }
                }
            }

            let missing = PhoneVisionProvider.allCases.filter { !deviceManager.isVisionProviderInstalled($0) }
            if !missing.isEmpty {
                Divider()
                ForEach(missing) { provider in
                    Button("\(provider.displayName) (Not Installed)") {}
                        .disabled(true)
                }
            }

            // Local Laya checks live next to the planner choice: one toggle
            // (there is no app-level Settings scene), plus the scorer state.
            Divider()
            Toggle("Local Checks on This Mac", isOn: semanticIfEnabled)
            Text("Laya Core ML: \(deviceManager.semanticIfState.menuStatus)")
                .foregroundStyle(.secondary)
            if deviceManager.semanticIfState.canWarm {
                Button("Load Local Checks Model…") {
                    deviceManager.warmSemanticIfScorer()
                }
            }
            if case .ready = deviceManager.semanticIfState {
                Button("Unload Local Checks Model") {
                    deviceManager.unloadSemanticIfScorer()
                }
            }
            if case .failed(let reason) = deviceManager.semanticIfState {
                Text(reason)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label(deviceManager.visionProvider.displayName, systemImage: "sparkles")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
        .disabled(deviceManager.isAnyPromptRunning)
        .help(deviceManager.visionProvider.screenRequestDescription)
        .sheet(isPresented: $editingModel) {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(editingProvider.displayName) Model").font(.title2)
                TextField("Model ID or alias", text: $modelDraft)
                    .textFieldStyle(.roundedBorder)
                Text("Use a model with image support available through your \(editingProvider.displayName) login.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel", role: .cancel) { editingModel = false }
                    Spacer()
                    Button("Use Model") {
                        deviceManager.visionProvider = editingProvider
                        deviceManager.setVisionModel(modelDraft, for: editingProvider)
                        editingModel = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!PhoneVisionProvider.isValidModel(modelDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                        || deviceManager.isAnyPromptRunning)
                }
            }
            .padding(24)
            .frame(width: 380)
        }
    }

    /// The selected planner carries a checkmark, like a picker row.
    @ViewBuilder
    private func providerLabel(_ provider: PhoneVisionProvider) -> some View {
        if provider == deviceManager.visionProvider {
            Label(provider.displayName, systemImage: "checkmark")
        } else {
            Text(provider.displayName)
        }
    }

    /// Choosing a model also selects its planner.
    private func modelSelection(for provider: PhoneVisionProvider) -> Binding<String> {
        Binding(
            get: { deviceManager.visionModel(for: provider) },
            set: { model in
                deviceManager.visionProvider = provider
                deviceManager.setVisionModel(model, for: provider)
            }
        )
    }

    /// The planner menu is also the Settings surface for local checks, since
    /// the app has no app-level Settings scene.
    private var semanticIfEnabled: Binding<Bool> {
        Binding(
            get: { deviceManager.semanticIfEnabled },
            set: { deviceManager.semanticIfEnabled = $0 }
        )
    }
}
