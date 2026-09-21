import AVFoundation
import CoreImage
import CoreMedia
import CoreMediaIO
import Foundation
import Observation
import os

/// A separate instance belongs to each physical phone. Explicit source IDs are
/// required; capture never falls back to another phone or an ordinary camera.
@Observable @MainActor
final class PhoneScreenCaptureService {
    private(set) var sources: [PhoneScreenSource] = []
    private(set) var selectedSourceID: String?
    private(set) var latestFrame: PhoneScreenFrame?
    private(set) var isRunning = false
    private(set) var isStarting = false
    private(set) var errorMessage: String?
    private(set) var authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    @ObservationIgnored private let engine = PhoneScreenCaptureEngine()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var waiting: [UUID: FrameWaiter] = [:]

    private struct FrameWaiter {
        let after: Date
        let sourceID: String
        let continuation: CheckedContinuation<PhoneScreenFrame, Error>
        let timeout: Task<Void, Never>
    }

    init() {
        engine.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in self?.receive(event) }
        }
    }

    deinit { engine.shutdown() }

    func refresh() async throws {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        do {
            sources = try await engine.sources()
            if let selectedSourceID, !sources.contains(where: { $0.id == selectedSourceID }), isRunning {
                await stop()
                errorMessage = PhoneScreenCaptureError.sourceUnavailable.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func requestCameraAuthorization() async -> Bool {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if authorizationStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        }
        return authorizationStatus == .authorized
    }

    func start(sourceID: String) async throws {
        guard !isStarting else { throw PhoneScreenCaptureError.runtime("Screen connection is already in progress.") }
        if isRunning, selectedSourceID == sourceID { return }
        isStarting = true
        defer { isStarting = false }
        await stop()
        try Task.checkCancellation()
        let requestedGeneration = UUID()
        generation = requestedGeneration
        let authorized = await requestCameraAuthorization()
        try Task.checkCancellation()
        guard generation == requestedGeneration else { throw CancellationError() }
        guard authorized else {
            errorMessage = PhoneScreenCaptureError.permissionDenied.localizedDescription
            throw PhoneScreenCaptureError.permissionDenied
        }
        selectedSourceID = sourceID
        errorMessage = nil
        do {
            let firstFrameAfter = Date()
            try await engine.start(sourceID: sourceID, generation: requestedGeneration)
            try Task.checkCancellation()
            guard generation == requestedGeneration else { throw CancellationError() }
            // Starting the CMIO graph does not prove the phone is delivering
            // usable images. Keep the source unavailable to the visual runner
            // until a fresh first frame arrives, with the same bounded wait used
            // between actions. A silent stream must not leave the UI waiting forever.
            _ = try await waitForFrame(sourceID: sourceID, after: firstFrameAfter)
            try Task.checkCancellation()
            guard generation == requestedGeneration else { throw CancellationError() }
            isRunning = true
        } catch {
            if generation == requestedGeneration {
                await stop()
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
            throw error
        }
    }

    func stop() async {
        generation = UUID()
        isRunning = false
        latestFrame = nil
        finishWaiters(throwing: PhoneScreenCaptureError.notRunning)
        await engine.stop()
    }

    /// Waits for a source-matched frame whose capture timestamp is strictly later
    /// than the requested barrier. Calling without a barrier requests a new frame.
    func capture(after: Date? = nil) async throws -> PhoneScreenFrame {
        try Task.checkCancellation()
        guard isRunning, let selectedSourceID else { throw PhoneScreenCaptureError.notRunning }
        let barrier = after ?? Date()
        return try await waitForFrame(sourceID: selectedSourceID, after: barrier)
    }

    private func waitForFrame(sourceID: String, after barrier: Date) async throws -> PhoneScreenFrame {
        if let latestFrame, latestFrame.sourceID == sourceID, latestFrame.capturedAt > barrier {
            return latestFrame
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    self?.finishWaiter(waiterID, throwing: PhoneScreenCaptureError.frameTimedOut)
                }
                waiting[waiterID] = FrameWaiter(after: barrier, sourceID: sourceID,
                    continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishWaiter(waiterID, throwing: CancellationError()) }
        }
    }

    private func receive(_ event: PhoneScreenCaptureEngine.Event) {
        switch event {
        case .frame(let frame, let eventGeneration):
            guard eventGeneration == generation, frame.sourceID == selectedSourceID else { return }
            if let latestFrame, frame.capturedAt <= latestFrame.capturedAt { return }
            latestFrame = frame
            let ready = waiting.filter { _, waiter in
                waiter.sourceID == frame.sourceID && frame.capturedAt > waiter.after
            }.map(\.key)
            for id in ready {
                guard let waiter = waiting.removeValue(forKey: id) else { continue }
                waiter.timeout.cancel()
                waiter.continuation.resume(returning: frame)
            }
        case .failed(let message, let eventGeneration):
            guard eventGeneration == generation else { return }
            generation = UUID()
            isRunning = false
            latestFrame = nil
            errorMessage = message
            finishWaiters(throwing: PhoneScreenCaptureError.runtime(message))
        case .sourcesChanged:
            Task { try? await refresh() }
        }
    }

    private func finishWaiter(_ id: UUID, throwing error: Error) {
        guard let waiter = waiting.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(throwing: error)
    }

    private func finishWaiters(throwing error: Error) {
        for id in Array(waiting.keys) { finishWaiter(id, throwing: error) }
    }
}

/// AVCaptureSession, its delegate, pixel buffers and CIContext stay on one serial
/// queue. Only immutable Sendable metadata/JPEGs leave that queue. This explicit
/// confinement is the reason for the unchecked Sendable conformance.
private final class PhoneScreenCaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case frame(PhoneScreenFrame, UUID)
        case failed(String, UUID)
        case sourcesChanged
    }

    private let queue = DispatchQueue(label: "com.joeblau.shortreel.phone-screen", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let logger = Logger(subsystem: "com.joeblau.shortreel", category: "PhoneScreen")
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var sourceID: String?
    private var generation = UUID()
    private var lastEncodedHostTime = -Double.infinity
    private var eventHandler: (@Sendable (Event) -> Void)?
    private var sessionObservers: [NSObjectProtocol] = []
    private var discoveryObservers: [NSObjectProtocol] = []
    private var sampleCount = 0
    private var frameCount = 0
    private var loggedRejections = Set<String>()

    func setEventHandler(_ handler: @escaping @Sendable (Event) -> Void) {
        queue.async { [self] in
            eventHandler = handler
            for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
                discoveryObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { [self] in
                        if let sourceID, AVCaptureDevice(uniqueID: sourceID)?.isConnected != true {
                            eventHandler?(.failed(PhoneScreenCaptureError.sourceUnavailable.localizedDescription, generation))
                            stopOnQueue()
                        }
                        eventHandler?(.sourcesChanged)
                    }
                })
            }
        }
    }

    func sources() async throws -> [PhoneScreenSource] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try enableScreenDevices()
                    continuation.resume(returning: screenDevices().map {
                        PhoneScreenSource(id: $0.uniqueID, name: $0.localizedName, deviceUniqueID: $0.uniqueID)
                    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func start(sourceID requestedSourceID: String, generation requestedGeneration: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    stopOnQueue()
                    try enableScreenDevices()
                    guard let device = screenDevices().first(where: { $0.uniqueID == requestedSourceID }) else {
                        throw PhoneScreenCaptureError.sourceUnavailable
                    }
                    let captureSession = AVCaptureSession()
                    captureSession.beginConfiguration()
                    if captureSession.canSetSessionPreset(.high) { captureSession.sessionPreset = .high }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard captureSession.canAddInput(input) else { throw PhoneScreenCaptureError.cannotAddInput }
                    captureSession.addInput(input)
                    let videoOutput = AVCaptureVideoDataOutput()
                    videoOutput.alwaysDiscardsLateVideoFrames = true
                    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    guard captureSession.canAddOutput(videoOutput) else { throw PhoneScreenCaptureError.cannotAddOutput }
                    captureSession.addOutput(videoOutput)
                    videoOutput.setSampleBufferDelegate(self, queue: queue)
                    captureSession.commitConfiguration()
                    session = captureSession
                    output = videoOutput
                    sourceID = requestedSourceID
                    generation = requestedGeneration
                    lastEncodedHostTime = -Double.infinity
                    sampleCount = 0
                    frameCount = 0
                    loggedRejections.removeAll()
                    observeSession(captureSession)
                    captureSession.startRunning()
                    guard captureSession.isRunning else { throw PhoneScreenCaptureError.cannotAddInput }
                    logger.info("Phone screen graph started; video connection active=\(videoOutput.connection(with: .video)?.isActive == true), clock available=\(captureSession.synchronizationClock != nil)")
                    continuation.resume()
                } catch {
                    stopOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                stopOnQueue()
                continuation.resume()
            }
        }
    }

    func shutdown() {
        queue.async { [self] in
            stopOnQueue()
            for observer in discoveryObservers { NotificationCenter.default.removeObserver(observer) }
            discoveryObservers.removeAll()
            eventHandler = nil
        }
    }

    private func stopOnQueue() {
        if session != nil {
            logger.info("Phone screen stopping after \(self.sampleCount) sample callbacks and \(self.frameCount) encoded frames")
        }
        output?.setSampleBufferDelegate(nil, queue: nil)
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
        sessionObservers.removeAll()
        session?.stopRunning()
        output = nil
        session = nil
        sourceID = nil
    }

    private func observeSession(_ captureSession: AVCaptureSession) {
        let observedGeneration = generation
        sessionObservers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
            object: captureSession, queue: nil) { [weak self] notification in
                let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
                    ?? "macOS stopped delivering phone screen frames."
                guard let self else { return }
                self.queue.async { [self] in
                    guard generation == observedGeneration else { return }
                    eventHandler?(.failed(message, observedGeneration))
                    stopOnQueue()
                }
            })
        sessionObservers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
            object: captureSession, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { [self] in
                    guard generation == observedGeneration else { return }
                    eventHandler?(.failed("The phone screen stream was interrupted. Reconnect the screen and try again.", observedGeneration))
                    stopOnQueue()
                }
            })
    }

    private func enableScreenDevices() throws {
        var property = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var enabled: UInt32 = 1
        let status = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &property,
            0, nil, UInt32(MemoryLayout<UInt32>.size), &enabled)
        guard status == noErr else { throw PhoneScreenCaptureError.discoveryFailed(status) }
    }

    private func screenDevices() -> [AVCaptureDevice] {
        var devices: [String: AVCaptureDevice] = [:]
        for mediaType in [AVMediaType.video, .muxed] {
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: mediaType, position: .unspecified)
            for device in discovery.devices where PhoneScreenSourceIdentity.isEligible(
                uniqueID: device.uniqueID, manufacturer: device.manufacturer, isExternal: device.deviceType == .external,
                modelID: device.modelID, isMuxed: device.hasMediaType(.muxed)) {
                devices[device.uniqueID] = device
            }
        }
        return Array(devices.values)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === self.output, let session, let sourceID else { return }
        sampleCount += 1
        if sampleCount == 1 {
            logger.info("Phone screen received its first sample; image available=\(CMSampleBufferGetImageBuffer(sampleBuffer) != nil), clock available=\(session.synchronizationClock != nil), presentation time=\(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)")
        }
        guard let clock = session.synchronizationClock else {
            logRejection("no synchronization clock")
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logRejection("sample contains no image buffer")
            return
        }
        let hostClock = CMClockGetHostTimeClock()
        let nowHost = CMClockGetTime(hostClock).seconds
        guard nowHost - lastEncodedHostTime >= 1.0 / 10.0 else { return }
        let sampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let captureHost = CMSyncConvertTime(sampleTime, from: clock, to: hostClock).seconds
        // Invalid timestamps must never be relabelled as a fresh observation.
        guard captureHost.isFinite, nowHost.isFinite, captureHost <= nowHost + 0.1 else {
            logRejection("invalid capture timestamp: sample=\(sampleTime.seconds), converted=\(captureHost), host=\(nowHost)")
            return
        }
        lastEncodedHostTime = nowHost
        let capturedAt = Date().addingTimeInterval(min(0, captureHost - nowHost))
        autoreleasepool {
            guard let frame = PhoneScreenFrameEncoder.encode(CIImage(cvPixelBuffer: pixelBuffer),
                using: context, capturedAt: capturedAt, sourceID: sourceID) else {
                logRejection("JPEG encoding failed")
                return
            }
            frameCount += 1
            if frameCount == 1 {
                logger.info("Phone screen encoded its first frame: \(frame.pixelWidth)x\(frame.pixelHeight), capture age=\(Date().timeIntervalSince(capturedAt))s")
            }
            eventHandler?(.frame(frame, generation))
        }
    }

    private func logRejection(_ reason: String) {
        // At most a few diagnostics per start, never a per-frame log stream.
        guard loggedRejections.count < 5, loggedRejections.insert(reason).inserted else { return }
        logger.error("Phone screen discarded a sample: \(reason, privacy: .public)")
    }
}
