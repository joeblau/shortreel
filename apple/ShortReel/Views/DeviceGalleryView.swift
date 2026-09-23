import AVFoundation
import SwiftData
import SwiftUI

struct DeviceGalleryView: View {
    var onAddDevice: () -> Void

    @Query(sort: \Device.createdAt) private var devices: [Device]
    @Environment(DeviceManager.self) private var deviceManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var promptDevice: Device?
    @State private var isInspectorPresented = false
    @State private var inspectorSegment: DeviceInspectorSegment = .agent
    @State private var refreshRevision = 0
    @State private var refreshing = false

    private var liveDevices: [Device] { devices.filter(\.isLive) }
    private let cardWidth: CGFloat = 260
    private let columnSpacing: CGFloat = 24
    private let galleryPadding: CGFloat = 24

    private struct RefreshID: Equatable {
        let devices: [PersistentIdentifier]
        let revision: Int
    }

    var body: some View {
        Group {
            if liveDevices.isEmpty {
                ContentUnavailableView {
                    Label("No Phones", systemImage: "iphone")
                } description: {
                    Text("Connect an iPhone to see its screen and give it instructions.")
                } actions: {
                    Button("Connect iPhone", action: onAddDevice)
                }
            } else {
                GeometryReader { geometry in
                    let columns = galleryColumns(for: geometry.size.width)

                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                            ForEach(liveDevices, id: \.persistentModelID) { device in
                                if device.isLive {
                                    DeviceScreenCard(
                                        device: device,
                                        width: cardWidth,
                                        isSelected: isInspectorPresented && promptDevice == device,
                                        onPrompt: {
                                            if isInspectorPresented, promptDevice == device {
                                                isInspectorPresented = false
                                            } else {
                                                promptDevice = device
                                                isInspectorPresented = true
                                            }
                                        },
                                        onSettings: {
                                            promptDevice = device
                                            inspectorSegment = .settings
                                            isInspectorPresented = true
                                        }
                                    )
                                }
                            }
                        }
                        .padding(galleryPadding)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: columns.count)
                    }
                }
            }
        }
        .navigationTitle("ShortReel")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    refreshRevision += 1
                } label: {
                    Label("Refresh Screens", systemImage: "arrow.clockwise")
                }
                .disabled(refreshing)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: onAddDevice) {
                    Label("Connect iPhone", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleInspector()
                } label: {
                    Label(isInspectorPresented ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(isInspectorPresented ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
            }
        }
        .task(id: RefreshID(devices: liveDevices.map(\.persistentModelID), revision: refreshRevision)) {
            refreshing = true
            await deviceManager.refreshDeviceScreens()
            if !Task.isCancelled { refreshing = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            refreshRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            refreshRevision += 1
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshRevision += 1 }
        }
        .inspector(isPresented: $isInspectorPresented) {
            DevicePromptInspector(device: promptDevice, segment: $inspectorSegment)
        }
        .onChange(of: inspectorSegment) { previous, _ in
            if previous == .settings { refreshRevision += 1 }
        }
        .onChange(of: isInspectorPresented) { _, presented in
            if !presented, inspectorSegment == .settings { refreshRevision += 1 }
        }
    }

    private func galleryColumns(for width: CGFloat) -> [GridItem] {
        let availableWidth = max(0, width - galleryPadding * 2)
        let count = max(1, Int((availableWidth + columnSpacing) / (cardWidth + columnSpacing)))
        return Array(
            repeating: GridItem(.fixed(cardWidth), spacing: columnSpacing, alignment: .top),
            count: min(count, max(1, liveDevices.count))
        )
    }

    private func toggleInspector() {
        if isInspectorPresented {
            isInspectorPresented = false
            return
        }
        if promptDevice == nil || promptDevice?.isLive == false { promptDevice = liveDevices.first }
        isInspectorPresented = true
    }
}

private struct DeviceScreenCard: View {
    let device: Device
    let width: CGFloat
    let isSelected: Bool
    let onPrompt: () -> Void
    let onSettings: () -> Void

    @Environment(DeviceManager.self) private var deviceManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if device.isLive {
            let capture = deviceManager.screenCapture(for: device)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    screenGlyph(capture)

                    Menu {
                        Button("Device Settings…", action: onSettings)
                        Divider()
                        if device.isConnected {
                            Button("Disconnect \(device.transport.displayName)") { deviceManager.disconnect(device) }
                        } else {
                            Button("Connect \(device.transport.displayName)") { deviceManager.connect(device) }
                                .disabled(device.connectionState == .pairing)
                        }
                        if capture.isRunning {
                            Button("Disconnect Screen") {
                                Task { await deviceManager.stopScreen(for: device) }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 20, height: 20)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .focusEffectDisabled()
                    .accessibilityLabel("Options for \(device.name)")
                }

                Button(action: onPrompt) {
                    screen(capture)
                        .frame(width: width - 20, height: (width - 20) * 19.5 / 9)
                        .background(Color.black.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Screen of \(device.name)")
                .help("Give \(device.name) instructions")

                DeviceStatusRow(device: device)
            }
            .padding(10)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.quaternary.opacity(0.35))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
        }
    }

    private func screen(_ capture: PhoneScreenCaptureService) -> some View {
        let frame = capture.latestFrame.flatMap {
            capture.isRunning && $0.sourceID == deviceManager.verifiedScreens[device.identifier] ? $0 : nil
        }
        let hasFrame = frame != nil
        return Color.clear.overlay {
            ZStack {
                screenSkeleton
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25)) { content in
                        content.opacity(hasFrame ? 0 : 1)
                    }

                Color.clear.overlay {
                    if let frame {
                        Image(decorative: frame.cgImage, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .accessibilityHidden(true)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25)) { content in
                    content.opacity(hasFrame ? 1 : 0)
                }

                if !hasFrame && !capture.isStarting && !capture.isRunning {
                    screenPlaceholder(capture)
                }
            }
        }
    }

    private var screenSkeleton: some View {
        VStack(spacing: 0) {
            HStack {
                Capsule().frame(width: 34, height: 8)
                Spacer()
                Capsule().frame(width: 40, height: 8)
            }
            .padding(16)
            Spacer()
            RoundedRectangle(cornerRadius: 22)
                .frame(height: 64)
                .padding(10)
        }
        .foregroundStyle(Color.primary.opacity(0.06))
        .background(Color.primary.opacity(0.025))
        .accessibilityHidden(true)
    }

    private func screenPlaceholder(_ capture: PhoneScreenCaptureService) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(placeholderTitle(capture))
                .font(.headline)
            Text(placeholderMessage(capture))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(24)
    }

    private func screenGlyph(_ capture: PhoneScreenCaptureService) -> some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            let hasFrame = capture.isRunning && capture.latestFrame.map {
                $0.sourceID == deviceManager.verifiedScreens[device.identifier]
            } == true
            let isFresh = hasFrame && capture.latestFrame.map { context.date.timeIntervalSince($0.capturedAt) < 5 } == true
            let status = isFresh ? "Live screen" : hasFrame ? "Last screen" : capture.isStarting ? "Connecting screen…" : "Screen offline"
            Group {
                if capture.isStarting {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "iphone.gen3")
                        .foregroundStyle(isFresh ? AnyShapeStyle(.green) : hasFrame ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
            }
            .frame(width: 20, height: 20)
            .help(status)
            .accessibilityLabel(status)
        }
    }

    private func placeholderTitle(_ capture: PhoneScreenCaptureService) -> String {
        if deviceManager.isScreenAutoConnectDisabled(for: device) { return "Screen disconnected" }
        if capture.authorizationStatus != .authorized { return "Screen access needed" }
        if capture.errorMessage != nil || deviceManager.screenConnectionErrors[device.identifier] != nil { return "Screen unavailable" }
        return capture.sources.isEmpty ? "Connect via USB" : "Set up this screen"
    }

    private func placeholderMessage(_ capture: PhoneScreenCaptureService) -> String {
        if deviceManager.isScreenAutoConnectDisabled(for: device) { return "Open screen settings to reconnect this iPhone’s live view." }
        if capture.authorizationStatus != .authorized { return "Open screen settings to allow this iPhone’s live view." }
        if let error = deviceManager.screenConnectionErrors[device.identifier] ?? capture.errorMessage { return error }
        return "Connect this iPhone by USB, unlock it, and confirm Trust to see its screen."
    }
}

enum DeviceInspectorSegment: String, CaseIterable {
    case agent, stage, settings
    var title: String { rawValue.capitalized }
}

private struct DevicePromptInspector: View {
    let device: Device?
    @Binding var segment: DeviceInspectorSegment

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if #available(macOS 27.0, *) {
                    inspectorPicker.pickerStyle(.tabs)
                } else {
                    inspectorPicker.pickerStyle(.segmented)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let device, device.isLive {
                DeviceInspectorHeader(device: device)

                switch segment {
                case .stage:
                    DeviceStageView(device: device)
                        .id(device.identifier)
                        .transition(.opacity)
                case .agent:
                    agentPane(device)
                        .transition(.opacity)
                case .settings:
                    DeviceSettingsView(device: device)
                        .transition(.opacity)
                }
            } else {
                ContentUnavailableView {
                    Label("No iPhone Selected", systemImage: "iphone")
                } description: {
                    Text("Select a phone’s screen to give it instructions.")
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: segment)
        .frame(minHeight: 0, maxHeight: .infinity)
        .inspectorColumnWidth(min: 320, ideal: 360, max: 460)
    }

    private var inspectorPicker: some View {
        Picker("Inspector", selection: $segment) {
            ForEach(DeviceInspectorSegment.allCases, id: \.rawValue) { option in
                Text(option.title).tag(option)
            }
        }
        .labelsHidden()
    }

    private func agentPane(_ device: Device) -> some View {
        VStack(spacing: 0) {
            DevicePromptHistory(device: device)
                .frame(minHeight: 0, maxHeight: .infinity)

            DevicePromptView(device: device)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DeviceInspectorHeader: View {
    let device: Device

    var body: some View {
        HStack(spacing: 8) {
            DeviceActivityGlyph(device: device)
            Text(device.name)
                .font(.headline)
                .lineLimit(1)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            PlannerMenu()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

private struct DeviceActivityGlyph: View {
    let device: Device

    @Environment(DeviceManager.self) private var deviceManager

    var body: some View {
        Group {
            if deviceManager.activity(for: device) != nil || device.connectionState == .pairing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: device.transport.symbolName)
                    .foregroundStyle(device.isConnected ? AnyShapeStyle(device.connectionState.color) : AnyShapeStyle(.tertiary))
            }
        }
        .frame(width: 20, height: 20)
    }
}

private struct DeviceStatusRow: View {
    let device: Device

    @Environment(DeviceManager.self) private var deviceManager

    private var status: String {
        deviceManager.activity(for: device)?.title
            ?? "\(device.transport.displayName) · \(device.connectionState.displayName)"
    }

    var body: some View {
        HStack(spacing: 6) {
            DeviceActivityGlyph(device: device)
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
