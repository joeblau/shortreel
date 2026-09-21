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
                    Group {
                        if workflow == .clearHomeScreen {
                            Button {
                                run(.clearHomeScreen)
                            } label: {
                                HStack(spacing: 10) {
                                    Label(workflow.title, systemImage: "\(index + 1).circle")
                                    Spacer(minLength: 8)
                                    Image(systemName: "play.fill")
                                        .accessibilityHidden(true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .accessibilityHint("Run Home Screen cleanup on \(device.name)")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        } else {
                            Button {
                                editingWorkflow = workflow
                            } label: {
                                Label(workflow.title, systemImage: "\(index + 1).circle")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .disabled(workflow == .clearHomeScreen && (session.isRunning || unavailableReason(session) != nil))
                    .help(workflow.summary)
                }

                if let reason = unavailableReason(session) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(16)
                }

                if let entry = session.entries.last {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            if session.isRunning { ProgressView().controlSize(.small) }
                            Text(entry.workflow?.title ?? "Agent request").font(.headline)
                            Spacer()
                            if session.isRunning {
                                Button("Stop") { session.cancel() }
                                    .keyboardShortcut(".", modifiers: .command)
                            }
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
                Text("Warm Up").font(.title2.bold())
                Text("Build a human-looking history on \(device.name).")
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

                Section("Session") {
                    Stepper(value: $warmUp.sessionMinutes, in: 5...60, step: 5) {
                        LabeledContent("Minutes", value: "\(warmUp.sessionMinutes)")
                            .monospacedDigit()
                    }
                    Stepper(value: $warmUp.itemsToView, in: 3...50) {
                        LabeledContent("Videos or posts to view", value: "\(warmUp.itemsToView)")
                            .monospacedDigit()
                    }
                    TextField("Niche", text: $warmUp.niche,
                              prompt: Text("What this persona browses, e.g. street photography"))
                }
            }
            .formStyle(.grouped)

            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("The session stays within the phase caps and stops at the limit above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let reason = unavailableReason(session) ?? (session.isRunning ? "Wait for the current task to finish before warming up." : warmUp.validationMessage) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Cancel", role: .cancel) { editingWorkflow = nil }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Run on \(device.name)") {
                        guard warmUp.validationMessage == nil, !session.isRunning,
                              unavailableReason(session) == nil, let persona = warmUpPersona else { return }
                        saveWarmUpPlan(for: persona)
                        run(.warmUp, details: warmUp.brief)
                        editingWorkflow = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(warmUp.validationMessage != nil || session.isRunning || unavailableReason(session) != nil)
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
                if let reason = unavailableReason(session) ?? (session.isRunning ? "Wait for the current task to finish before creating a draft." : slideshow.validationMessage) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Cancel", role: .cancel) { editingWorkflow = nil }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Create Draft") {
                        guard slideshow.validationMessage == nil, !session.isRunning,
                              unavailableReason(session) == nil else { return }
                        run(.createContent, details: slideshow.brief)
                        editingWorkflow = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(slideshow.validationMessage != nil || session.isRunning || unavailableReason(session) != nil)
                }
            }
            .padding(24)
        }
        .frame(width: 540, height: 660)
    }
}
