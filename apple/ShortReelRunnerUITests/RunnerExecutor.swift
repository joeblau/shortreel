import UIKit
import XCTest

struct RunnerFailure: Error {
    var body: RunnerErrorBody

    init(_ code: RunnerErrorBody.Code, _ message: String) {
        body = RunnerErrorBody(code: code, message: message)
    }
}

@MainActor
final class RunnerExecutor {
    private(set) var lastActivatedBundleID: String?

    private static let springboardBundleID = "com.apple.springboard"

    func health() -> HealthResponse {
        HealthResponse(
            status: "ok",
            version: PhoneRunnerProtocol.version,
            deviceModel: UIDevice.current.model,
            osVersion: UIDevice.current.systemVersion
        )
    }

    func tap(_ request: TapRequest) throws {
        guard [request.point.x, request.point.y].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              [1, 2].contains(request.tapCount ?? 1),
              request.holdDuration == nil || (request.holdDuration!.isFinite && (0.2...3).contains(request.holdDuration!)),
              request.holdDuration == nil || (request.tapCount ?? 1) == 1 else {
            throw RunnerFailure(.unsupported, "Invalid tap coordinates, count, or hold duration.")
        }
        let point = try app(for: request.target)
            .coordinate(withNormalizedOffset: CGVector(dx: request.point.x, dy: request.point.y))
        if let duration = request.holdDuration { point.press(forDuration: duration) }
        else if request.tapCount == 2 { point.doubleTap() }
        else { point.tap() }
        settle(request.settle)
    }

    func drag(_ request: DragRequest) throws {
        guard [request.from.x, request.from.y, request.to.x, request.to.y].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              request.duration.isFinite, (0.1...3).contains(request.duration),
              (request.pressDuration ?? 0).isFinite, (0...3).contains(request.pressDuration ?? 0),
              (request.holdDuration ?? 0).isFinite, (0...3).contains(request.holdDuration ?? 0),
              request.curve == .linear || ((request.pressDuration ?? 0) == 0 && (request.holdDuration ?? 0) == 0) else {
            throw RunnerFailure(.unsupported, "Invalid drag coordinates or timing; held drags require a continuous linear gesture.")
        }

        let app = try app(for: request.target)
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: request.from.x, dy: request.from.y))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: request.to.x, dy: request.to.y))
        let duration = max(request.duration, 0.01)
        let fromPoint = from.screenPoint
        let toPoint = to.screenPoint

        switch request.curve {
        case .linear:
            from.press(
                forDuration: request.pressDuration ?? 0,
                thenDragTo: to,
                withVelocity: Self.velocity(from: fromPoint, to: toPoint, duration: duration),
                thenHoldForDuration: request.holdDuration ?? 0
            )
        case .smoothstep:
            var anchor = from
            var anchorPoint = fromPoint
            for t in [1.0 / 3, 2.0 / 3, 1.0] {
                let s = t * t * (3 - 2 * t)
                let point = CGPoint(
                    x: fromPoint.x + (toPoint.x - fromPoint.x) * s,
                    y: fromPoint.y + (toPoint.y - fromPoint.y) * s
                )
                let segment = anchor.withOffset(CGVector(dx: point.x - anchorPoint.x, dy: point.y - anchorPoint.y))
                anchor.press(
                    forDuration: 0,
                    thenDragTo: segment,
                    withVelocity: Self.velocity(from: anchorPoint, to: point, duration: duration / 3),
                    thenHoldForDuration: 0
                )
                anchor = segment
                anchorPoint = point
            }
        }
        settle(request.settle)
    }

    func swipe(_ request: SwipeRequest) throws {
        let app = try app(for: request.target)
        switch request.direction {
        case .up: app.swipeUp()
        case .down: app.swipeDown()
        case .left: app.swipeLeft()
        case .right: app.swipeRight()
        }
        settle(request.settle)
    }

    func pinch(_ request: PinchRequest) throws {
        try app(for: request.target).pinch(withScale: CGFloat(request.scale), velocity: CGFloat(request.velocity))
        settle(request.settle)
    }

    func type(_ request: TypeRequest) throws {
        let app = try app(for: request.target)
        app.typeText(request.text)
        settle(request.settle)
    }

    func pressKey(_ request: KeyRequest) throws {
        let app = try app(for: .foreground)
        switch request.key {
        case .search: app.typeKey(" ", modifierFlags: .command)
        case .selectAll: app.typeKey("a", modifierFlags: .command)
        case .addressBar: app.typeKey("l", modifierFlags: .command)
        case .enter: app.typeText("\n")
        case .escape: app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        case .backspace: app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        case .tab: app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
        case .shiftTab: app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: .shift)
        case .space: app.typeKey(" ", modifierFlags: [])
        case .deleteForward: app.typeKey(XCUIKeyboardKey.forwardDelete.rawValue, modifierFlags: [])
        case .arrowUp: app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
        case .arrowDown: app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        case .arrowLeft: app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        case .arrowRight: app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        case .copy: app.typeKey("c", modifierFlags: .command)
        case .cut: app.typeKey("x", modifierFlags: .command)
        case .paste: app.typeKey("v", modifierFlags: .command)
        case .undo: app.typeKey("z", modifierFlags: .command)
        case .redo: app.typeKey("z", modifierFlags: [.command, .shift])
        }
    }

    func pressButton(_ request: PressButtonRequest) throws {
        let button: XCUIDevice.Button
        switch request.button {
        case .home: button = .home
        #if targetEnvironment(simulator)
        case .volumeUp, .volumeDown:
            throw RunnerFailure(.unsupported, "Volume buttons are unavailable in the iPhone simulator")
        #else
        case .volumeUp: button = .volumeUp
        case .volumeDown: button = .volumeDown
        #endif
        case .lock:
            throw RunnerFailure(.unsupported, "pressButton(lock) is unavailable: public XCTest has no lock XCUIDeviceButton case")
        }
        XCUIDevice.shared.press(button)
    }

    func openApp(_ request: OpenAppRequest) throws {
        XCUIApplication(bundleIdentifier: request.bundleID).activate()
        lastActivatedBundleID = request.bundleID
    }

    func performAlertAction(_ request: AlertActionRequest) throws {
        let alert = try app(for: request.target).alerts.firstMatch
        guard alert.exists else {
            throw RunnerFailure(.elementNotFound, "No alert on target \(request.target.rawValue)")
        }
        let buttons = alert.buttons.allElementsBoundByIndex
        guard !buttons.isEmpty else {
            throw RunnerFailure(.elementNotFound, "Alert on target \(request.target.rawValue) has no buttons")
        }
        let preferred: [String]
        let fallback: XCUIElement
        switch request.action {
        case .accept:
            preferred = ["allow", "ok", "continue", "yes", "accept", "open", "settings", "turn on", "while using"]
            fallback = buttons[buttons.count - 1]
        case .dismiss:
            preferred = ["cancel", "don’t allow", "don't allow", "dismiss", "no", "not now", "close", "ask app not to track"]
            fallback = buttons[0]
        }
        let match = buttons.first { button in
            let label = button.label.lowercased()
            return preferred.contains { label.contains($0) }
        }
        (match ?? fallback).tap()
    }

    func appState(target: RunnerTarget) throws -> AppStateResponse {
        let state: AppStateResponse.State
        let app = try app(for: target)
        switch app.state {
        case .runningForeground: state = .foreground
        case .runningBackground, .runningBackgroundSuspended: state = .background
        case .notRunning: state = .notRunning
        case .unknown: state = .unknown
        @unknown default: state = .unknown
        }
        return AppStateResponse(
            bundleID: SRApplicationBundleID(app),
            state: state,
            springboardForeground: springboard().state == .runningForeground
        )
    }

    func tree(target: RunnerTarget, maxDepth _: Int?) throws -> TreeResponse {
        TreeResponse(target: target, tree: try app(for: target).debugDescription)
    }

    func alerts(target: RunnerTarget) throws -> AlertsResponse {
        let infos = try app(for: target).alerts.allElementsBoundByIndex.map { alert in
            AlertInfo(
                title: alert.label,
                buttonLabels: alert.buttons.allElementsBoundByIndex.map(\.label)
            )
        }
        return AlertsResponse(target: target, alerts: infos)
    }

    func locked() -> LockedResponse {
        if let bundleID = lastActivatedBundleID,
           XCUIApplication(bundleIdentifier: bundleID).state == .runningForeground {
            return LockedResponse(locked: false)
        }
        let springboard = springboard()
        guard springboard.state == .runningForeground else {
            return LockedResponse(locked: false)
        }
        let markers = [
            springboard.staticTexts["Swipe up to open"],
            springboard.staticTexts["Swipe up to unlock"],
            springboard.staticTexts["Press home to open"],
            springboard.staticTexts["Press home to unlock"],
            springboard.buttons["Emergency"],
        ]
        return LockedResponse(locked: markers.contains { $0.exists })
    }

    func screenshot() -> Data {
        XCUIScreen.main.screenshot().pngRepresentation
    }

    private func app(for target: RunnerTarget) throws -> XCUIApplication {
        if target == .springboard { return springboard() }
        guard let app = SRForegroundApplication() else {
            throw RunnerFailure(.snapshotFailed, "XCTest could not identify the foreground app. Unlock the phone and retry.")
        }
        lastActivatedBundleID = SRApplicationBundleID(app)
        return app
    }

    private func springboard() -> XCUIApplication {
        XCUIApplication(bundleIdentifier: Self.springboardBundleID)
    }

    private func settle(_ mode: RunnerSettle) {
        if mode == .animation {
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private static func velocity(from: CGPoint, to: CGPoint, duration: TimeInterval) -> XCUIGestureVelocity {
        let distance = hypot(to.x - from.x, to.y - from.y)
        return XCUIGestureVelocity(rawValue: max(1, distance / CGFloat(duration)))
    }
}
