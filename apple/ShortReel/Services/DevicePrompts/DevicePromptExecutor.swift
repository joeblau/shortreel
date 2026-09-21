import Foundation

/// Converts validated intent into input on one specific Bluetooth phone.
@MainActor
enum DevicePromptExecutor {
    static func perform(_ action: PhonePromptAction, using host: any DeviceHost, on device: DeviceDescriptor,
                        expect overrideExpectation: DeviceActionExpectation? = nil,
                        checking checkFactory: DevicePromptCheckFactory? = nil) async throws {
        try Task.checkCancellation()
        try DevicePromptPlanner.validate(.init(actions: [action]))
        // The factory captures any pre-action baseline. Without a factory the
        // action runs exactly as it always has, with no verification.
        let check = await checkFactory?(overrideExpectation ?? action.expectation)
        try await execute(action, using: host, on: device)
        guard let check else { return }
        try await verify(check: check) {
            try await execute(action, using: host, on: device)
        }
    }

    /// Verify-then-continue with the failure ladder from
    /// docs/execute-leg-design.md: re-check before repeating any input (the
    /// effect may already be present, and repeating a landed action can
    /// double-apply it), retry the action once, then abort with the evidence.
    private static func verify(check: DevicePromptCheck, retry: () async throws -> Void) async throws {
        if await check().isResolved { return }
        if await check().isResolved { return }
        try Task.checkCancellation()
        try await retry()
        if case .failed(let evidence) = await check() {
            throw DevicePromptVerificationError.failed(evidence)
        }
    }

    private static func execute(_ action: PhonePromptAction, using host: any DeviceHost, on device: DeviceDescriptor) async throws {
        switch action {
        case .home:
            try await host.pressKey(.home, on: device)
        case .openApp, .search:
            // Compound scripted sequences are gone: the visual loop observes
            // one frame between every primitive, and validated() already
            // rejects these model-side. Reaching here is a wiring bug.
            throw PhoneVisionError.invalidDecision("Choose one visible interaction at a time.")
        case .typeText(let text):
            try await host.type(text, on: device)
        case .tap(let x, let y):
            guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                throw PhonePromptPlanningError.needsClarification("Tap coordinates must be between 0% and 100%.")
            }
            try await host.tap(NormalizedPoint(x: x, y: y), on: device)
        case .doubleTap(let x, let y):
            try await host.doubleTap(.init(x: x, y: y), on: device)
        case .longPress(let x, let y, let seconds):
            try await host.longPress(.init(x: x, y: y), seconds: seconds, on: device)
        case .timedDrag(let x1, let y1, let x2, let y2, let duration, let press, let hold):
            try await host.drag(from: .init(x: x1, y: y1), to: .init(x: x2, y: y2),
                duration: duration, pressDuration: press, holdDuration: hold, on: device)
        case .drag(let x1, let y1, let x2, let y2):
            try DevicePromptPlanner.validate(.init(actions: [action]))
            try await host.swipe(from: .init(x: x1, y: y1), to: .init(x: x2, y: y2), on: device)
        case .swipe(let direction):
            let start: NormalizedPoint, end: NormalizedPoint
            switch direction {
            case .up: (start, end) = (.init(x: 0.5, y: 0.75), .init(x: 0.5, y: 0.25))
            case .down: (start, end) = (.init(x: 0.5, y: 0.25), .init(x: 0.5, y: 0.75))
            case .left: (start, end) = (.init(x: 0.75, y: 0.5), .init(x: 0.25, y: 0.5))
            case .right: (start, end) = (.init(x: 0.25, y: 0.5), .init(x: 0.75, y: 0.5))
            }
            try await host.swipe(from: start, to: end, on: device)
        case .press(let key):
            let deviceKey: DeviceKeyboardKey
            switch key {
            case .enter: deviceKey = .enter
            case .escape: deviceKey = .escape
            case .backspace: deviceKey = .backspace
            case .tab: deviceKey = .tab
            case .search: deviceKey = .search
            case .selectAll: deviceKey = .selectAll
            case .addressBar: deviceKey = .addressBar
            case .assistiveTouch:
                try await host.openAssistiveTouchMenu(on: device)
                return
            case .space: deviceKey = .space
            case .shiftTab: deviceKey = .shiftTab
            case .deleteForward: deviceKey = .deleteForward
            case .arrowUp: deviceKey = .arrowUp
            case .arrowDown: deviceKey = .arrowDown
            case .arrowLeft: deviceKey = .arrowLeft
            case .arrowRight: deviceKey = .arrowRight
            case .copy: deviceKey = .copy
            case .cut: deviceKey = .cut
            case .paste: deviceKey = .paste
            case .undo: deviceKey = .undo
            case .redo: deviceKey = .redo
            case .appSwitcher:
                try await host.openAppSwitcher(on: device)
                try await Task.sleep(for: .milliseconds(400))
                return
            }
            try await host.pressKey(deviceKey, on: device)
        }
        try await Task.sleep(for: .milliseconds(400))
    }
}

/// An action's expectation never verified, after the failure ladder ran. The
/// evidence string lands in the Requests UI status.
enum DevicePromptVerificationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self { case .failed(let evidence): evidence }
    }
}
