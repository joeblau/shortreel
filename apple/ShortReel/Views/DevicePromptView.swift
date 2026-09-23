import SwiftUI

struct DevicePromptView: View {
    let device: Device

    @Environment(DeviceManager.self) private var deviceManager
    @FocusState private var composerFocused: Bool

    var body: some View {
        @Bindable var session = deviceManager.promptSession(for: device)

        VStack(alignment: .leading, spacing: 8) {
            DeviceRunQueueView(session: session)
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

struct DevicePromptHistory: View {
    let device: Device

    @Environment(DeviceManager.self) private var deviceManager
    @State private var contentSize = CGSize.zero

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
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(session.entries) { entry in
                            ChatTranscriptEntry(entry: entry)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
                }
                .defaultScrollAnchor(.bottom)
                .task(id: scrollRevision(session)) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .id(device.identifier)
        }
    }

    private func scrollRevision(_ session: DevicePromptSession) -> Int {
        var hasher = Hasher()
        hasher.combine(contentSize.width)
        hasher.combine(contentSize.height)
        for entry in session.entries {
            hasher.combine(entry.id)
            hasher.combine(entry.updatedAt)
            hasher.combine(entry.steps.count)
            hasher.combine(entry.status)
            hasher.combine(entry.message)
        }
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

    private func statusColor(_ status: DevicePromptStatus) -> Color {
        switch status {
        case .planning, .running: .accentColor
        case .queued: .secondary
        case .cancelled, .completed: .secondary
        case .failed: .red
        case .needsInput, .needsReview: .orange
        }
    }

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

private struct TypingIndicator: View {
    var body: some View {
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

            Divider()
            Text("Workflow Classification (Required)")
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

    @ViewBuilder
    private func providerLabel(_ provider: PhoneVisionProvider) -> some View {
        if provider == deviceManager.visionProvider {
            Label(provider.displayName, systemImage: "checkmark")
        } else {
            Text(provider.displayName)
        }
    }

    private func modelSelection(for provider: PhoneVisionProvider) -> Binding<String> {
        Binding(
            get: { deviceManager.visionModel(for: provider) },
            set: { model in
                deviceManager.visionProvider = provider
                deviceManager.setVisionModel(model, for: provider)
            }
        )
    }

}
