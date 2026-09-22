import SwiftData
import SwiftUI

/// The pipeline stages for the selected phone, shown by the inspector's
/// Stage segment. Ordering matters: a clean home screen, then warm-up, then
/// content creation. Cleanup is the primary action and starts with one click.
struct DeviceStageView: View {
    let device: Device

    @Environment(DeviceManager.self) private var deviceManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Persona.displayName) private var personas: [Persona]
    @Query private var warmUpPlans: [WarmUpPlan]
    @State private var editingWorkflow: DeviceWorkflow?
    @State private var warmUpActivity: WarmUpActivity = .watch
    @State private var warmUp = WarmUpConfiguration()
    @State private var warmUpPersona: Persona?
    @State private var showAddWarmUpPersona = false
    @State private var contentType: ContentCreationType = .slideshow
    @State private var slideshow = SlideshowConfiguration()

    var body: some View {
        let session = deviceManager.promptSession(for: device)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(DeviceWorkflow.allCases.enumerated()), id: \.element.id) { index, workflow in
                    if workflow == .warmUp {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Warm Up", systemImage: "2.circle")
                                .font(.headline)
                                .padding(.horizontal, 12)
                            ForEach(WarmUpActivity.allCases) { activity in
                                stageButton(activity.title, symbol: activity.symbol, session: session) {
                                    warmUpActivity = activity
                                    editingWorkflow = .warmUp
                                }
                            }
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 20))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    } else {
                        stageButton(workflow.title, symbol: "\(index + 1).circle", session: session) {
                            if workflow == .clearHomeScreen { run(.clearHomeScreen) }
                            else { editingWorkflow = workflow }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .help(workflow.summary)
                    }
                }

                if let reason = unavailableReason(session) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(16)
                }

                // A failed scorer load never blocks a stage; say here why
                // local checks are off instead.
                if let notice = deviceManager.semanticIfState.localChecksOffNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }

                DeviceRunQueueView(session: session)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                if let entry = session.entries.last(where: { $0.status.isActive }) ?? session.entries.last {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            if session.isRunning { ProgressView().controlSize(.small) }
                            Text(entry.scriptTitle ?? entry.workflow?.title ?? "Agent request").font(.headline)
                            Spacer()
                            if session.isRunning {
                                Button("Stop") { session.cancel() }
                                    .keyboardShortcut(".", modifiers: .command)
                            }
                        }
                        if let progress = entry.scriptProgress {
                            Text(progress).font(.callout)
                        }
                        Text(entry.status.displayName).font(.subheadline)
                        Text(entry.message).font(.callout).foregroundStyle(.secondary)
                        if let step = entry.steps.last {
                            Text("Step \(step.number): \(step.detail)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("View all steps in Agent.").font(.caption).foregroundStyle(.tertiary)
                    }
                    .textSelection(.enabled)
                    .padding(16)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .sheet(item: $editingWorkflow) { workflow in
            switch workflow {
            case .createContent:
                contentConfiguration(session: session)
            case .warmUp:
                warmUpConfiguration(session: session)
            case .clearHomeScreen:
                EmptyView()
            }
        }
    }

    private func stageButton(_ title: String, symbol: String, session: DevicePromptSession,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Label(title, systemImage: symbol)
                Spacer(minLength: 8)
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .accessibilityLabel("\(session.isRunning ? "Queue" : "Run") \(title) on \(device.name)")
        .disabled(unavailableReason(session) != nil)
    }

    private func unavailableReason(_ session: DevicePromptSession) -> String? {
        if !device.isLive { return "This iPhone is no longer available." }
        return session.unavailableReason ?? session.screenUnavailableReason
    }

    private func run(_ workflow: DeviceWorkflow, details: String = "") {
        deviceManager.prepareVisionProvider()
        deviceManager.promptSession(for: device).submit(workflow: workflow, details: details)
    }

    private func warmUpPlan(for persona: Persona, platform: Platform) -> WarmUpPlan? {
        warmUpPlans.first { $0.persona?.persistentModelID == persona.persistentModelID && $0.platform == platform }
    }

    /// Prefill the form from the device's bound persona and its saved plan.
    private func prepareWarmUp() {
        let available = personas.filter { $0.isLive && $0.isActive }
        let persona = available.first { $0.device?.persistentModelID == device.persistentModelID }
            ?? available.first { $0 == warmUpPersona }
            ?? available.first
        warmUpPersona = persona
        warmUp = WarmUpConfiguration()
        warmUp.activity = warmUpActivity
        applyWarmUpDefaults()
    }

    /// Pull saved session values and the date-derived phase for the
    /// currently selected persona and platform.
    private func applyWarmUpDefaults() {
        guard let persona = warmUpPersona, persona.isLive else {
            warmUp.profileName = ""
            warmUp.profileHandle = ""
            warmUp.profileNarrative = ""
            return
        }
        warmUp.platform = persona.network
        warmUp.profileName = persona.displayName
        warmUp.profileHandle = persona.handle
        warmUp.profileNarrative = persona.narrative
        if let plan = warmUpPlan(for: persona, platform: warmUp.platform) {
            warmUp.phaseIndex = plan.currentPhaseIndex
            warmUp.sessionMinutes = plan.lastSessionMinutes
            warmUp.itemsToView = plan.lastItemsToView
            warmUp.niche = plan.niche
        } else {
            warmUp.phaseIndex = 0
            if warmUp.niche.isEmpty {
                warmUp.niche = defaultNiche(for: persona)
            }
        }
    }

    /// A starting niche guess from the persona's narrative.
    private func defaultNiche(for persona: Persona) -> String {
        persona.narrative
            .split(separator: ".").first
            .map(String.init) ?? ""
    }

    private func warmUpConfiguration(session: DevicePromptSession) -> some View {
        let phases = WarmUpPlaybook.phases(for: warmUp.platform)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Warm Up · \(warmUpActivity.title)").font(.title2.bold())
                Text("Run the \(warmUpActivity.title.lowercased()) script on \(device.name).")
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            Form {
                Section("Agent profile") {
                    Picker("Profile", selection: $warmUpPersona) {
                        Text("None").tag(Persona?.none)
                        ForEach(personas.filter { $0.isLive && $0.isActive }, id: \.persistentModelID) { persona in
                            Text("\(persona.displayName) (@\(persona.handle))").tag(Persona?.some(persona))
                        }
                    }
                    .onChange(of: warmUpPersona) { _, _ in applyWarmUpDefaults() }
                    Button("Add Persona…") { showAddWarmUpPersona = true }
                    if let persona = warmUpPersona {
                        Text(persona.narrative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }

                Section {
                    Picker("Platform", selection: $warmUp.platform) {
                        ForEach(WarmUpPlaybook.platforms, id: \.self) { platform in
                            Text(platform.displayName).tag(platform)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(warmUpPersona != nil)
                    .onChange(of: warmUp.platform) { _, _ in applyWarmUpDefaults() }
                }

                Section {
                    Picker("Phase", selection: $warmUp.phaseIndex) {
                        ForEach(Array(phases.enumerated()), id: \.offset) { index, plan in
                            Text(plan.title).tag(index)
                        }
                    }
                    if !warmUp.phase.guidance.isEmpty {
                        Text(warmUp.phase.guidance)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Phase", systemImage: "calendar")
                } footer: {
                    if let persona = warmUpPersona,
                       let plan = warmUpPlan(for: persona, platform: warmUp.platform) {
                        Text("Warm-up day \(plan.dayIndex) for this persona on \(warmUp.platform.displayName).")
                    } else {
                        Text("No schedule yet — the first run starts day 1 for this persona on \(warmUp.platform.displayName).")
                    }
                }

                if let script = warmUp.script {
                    Section("Script") {
                        ForEach(Array(script.steps.enumerated()), id: \.offset) { index, step in
                            Label(step.title, systemImage: "\(index + 1).circle")
                                .font(.callout)
                        }
                        if warmUpActivity == .watch {
                            Text(script.maximumVideoDurationSeconds == nil
                                 ? "Repeat watching and advancing until the item or time limit is reached."
                                 : "Skip videos longer than \(script.maximumVideoDurationSeconds ?? 60) seconds. Skipped videos do not count toward the viewing limit.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Session") {
                    Stepper(value: $warmUp.sessionMinutes, in: 5...60, step: 5) {
                        LabeledContent("Minutes", value: "\(warmUp.sessionMinutes)")
                            .monospacedDigit()
                    }
                    if warmUpActivity == .watch {
                        Stepper(value: $warmUp.itemsToView, in: 3...50) {
                            LabeledContent("Videos or posts to view", value: "\(warmUp.itemsToView)")
                                .monospacedDigit()
                        }
                    }
                    TextField("Niche", text: $warmUp.niche,
                              prompt: Text("What this persona browses, e.g. street photography"))
                    if warmUpActivity != .watch {
                        TextField(warmUpActivity == .post ? "Post instructions and media" : "Comment instructions (optional)",
                                  text: $warmUp.contentInstructions, axis: .vertical)
                            .lineLimit(3...6)
                        Text(warmUpActivity == .post
                             ? "Publishes one post. Describe the content and identify existing photos or video to use."
                             : "Reads or watches one item, then publishes one relevant comment in this persona’s voice.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("The agent first confirms the phone is signed in as @\(warmUp.normalizedHandle.isEmpty ? "handle" : warmUp.normalizedHandle), then stays within the phase caps and stops at the limit above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let reason = unavailableReason(session) ?? warmUp.validationMessage {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Cancel", role: .cancel) { editingWorkflow = nil }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("\(session.isRunning || session.queuePaused ? "Queue " : "")\(warmUpActivity.title) on \(device.name)") {
                        guard warmUp.validationMessage == nil,
                              unavailableReason(session) == nil, let persona = warmUpPersona else { return }
                        saveWarmUpPlan(for: persona)
                        deviceManager.prepareVisionProvider()
                        session.submit(workflow: .warmUp, details: warmUp.scriptBrief, warmUpScript: warmUp.script)
                        editingWorkflow = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(warmUp.validationMessage != nil || unavailableReason(session) != nil)
                }
            }
            .padding(24)
        }
        .frame(width: 540, height: 660)
        .onAppear(perform: prepareWarmUp)
        .sheet(isPresented: $showAddWarmUpPersona) {
            AddPersonaView { persona in
                warmUpPersona = persona
                applyWarmUpDefaults()
            }
        }
    }

    private func saveWarmUpPlan(for persona: Persona) {
        if let plan = warmUpPlan(for: persona, platform: warmUp.platform) {
            plan.niche = warmUp.niche
            plan.lastSessionMinutes = warmUp.sessionMinutes
            plan.lastItemsToView = warmUp.itemsToView
        } else {
            modelContext.insert(WarmUpPlan(
                platform: warmUp.platform,
                niche: warmUp.niche,
                lastSessionMinutes: warmUp.sessionMinutes,
                lastItemsToView: warmUp.itemsToView,
                persona: persona
            ))
        }
        try? modelContext.save()
    }

    private func contentConfiguration(session: DevicePromptSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Create Content").font(.title2.bold())
                Text("Configure a draft for \(device.name).")
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            Form {
                Section("Content") {
                    Picker("Type", selection: $contentType) {
                        ForEach(ContentCreationType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    TextField("Destination app", text: $slideshow.destination, prompt: Text("TikTok, Instagram…"))
                }

                switch contentType {
                case .slideshow:
                    Section {
                        TextField("Topic", text: $slideshow.topic,
                                  prompt: Text("What is your slideshow about?"), axis: .vertical)
                            .lineLimit(2...3)
                        Stepper(value: $slideshow.slideCount, in: 2...20) {
                            LabeledContent("Slides", value: "\(slideshow.slideCount)")
                                .monospacedDigit()
                        }
                        TextField("Photos to use", text: $slideshow.photoSelection,
                                  prompt: Text("Album name, which photos, and their order"), axis: .vertical)
                            .lineLimit(2...4)
                    } header: {
                        Label("Slideshow", systemImage: "rectangle.stack")
                    } footer: {
                        Text("Use photos already available on \(device.name).")
                    }

                    Section("Details") {
                        TextField("Caption", text: $slideshow.caption,
                                  prompt: Text("Optional — leave blank to write one from your topic"), axis: .vertical)
                            .lineLimit(2...4)
                        TextField("Instructions", text: $slideshow.instructions,
                                  prompt: Text("Optional — tone, slide text, or other directions"), axis: .vertical)
                            .lineLimit(2...4)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Saved as a draft for you to review before publishing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let reason = unavailableReason(session) ?? slideshow.validationMessage {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Cancel", role: .cancel) { editingWorkflow = nil }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(session.isRunning || session.queuePaused ? "Queue Draft" : "Create Draft") {
                        guard slideshow.validationMessage == nil,
                              unavailableReason(session) == nil else { return }
                        run(.createContent, details: slideshow.brief)
                        editingWorkflow = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(slideshow.validationMessage != nil || unavailableReason(session) != nil)
                }
            }
            .padding(24)
        }
        .frame(width: 540, height: 660)
    }
}
