import Foundation

/// Wire protocol between ShortReel (Mac) and ShortReelRunner (on-device XCTest
/// bundle). This file is compiled into three targets: the macOS app, the iOS
/// stub app, and the UI-testing bundle, so it must stay dependency-free
/// Foundation-only. Design: docs/phone-runner-design.md
enum PhoneRunnerProtocol {
    static let port: UInt16 = 8700
    static let version = 3

    static let healthPath = "/health"
    static let tapPath = "/action/tap"
    static let dragPath = "/action/drag"
    static let swipePath = "/action/swipe"
    static let pinchPath = "/action/pinch"
    static let typePath = "/action/type"
    static let keyPath = "/action/key"
    static let pressButtonPath = "/action/pressButton"
    static let openAppPath = "/action/openApp"
    static let alertActionPath = "/action/alert"
    static let appStatePath = "/state/app"
    static let treePath = "/state/tree"
    static let alertsPath = "/state/alerts"
    static let lockedPath = "/state/locked"
    static let screenshotPath = "/state/screenshot"
}

/// Which app an action or state query binds to. `springboard` covers the home
/// screen, App Library, Control Center, notification banners, and system
/// alerts (docs/phone-runner-design.md).
enum RunnerTarget: String, Codable, Sendable {
    case foreground
    case springboard
}

/// How long the on-device side waits for the UI to settle around an action.
/// `idle` uses XCTest's default quiescence; `animation` adds a pause.
/// `none` adds no extra wait, but cannot disable XCTest's built-in quiescence.
enum RunnerSettle: String, Codable, Sendable {
    case idle
    case animation
    case none
}

struct RunnerPoint: Codable, Sendable, Hashable {
    /// Normalized 0...1 on each axis, matching NormalizedPoint in the app.
    var x: Double
    var y: Double
}

// MARK: - Action requests

struct TapRequest: Codable, Sendable {
    var target: RunnerTarget = .foreground
    var point: RunnerPoint
    var tapCount: Int? = nil
    var holdDuration: TimeInterval? = nil
    var settle: RunnerSettle = .idle
}

struct DragRequest: Codable, Sendable {
    enum Curve: String, Codable, Sendable {
        case linear
        case smoothstep
    }

    var target: RunnerTarget = .foreground
    var from: RunnerPoint
    var to: RunnerPoint
    var duration: TimeInterval = 0.4
    var pressDuration: TimeInterval? = nil
    var holdDuration: TimeInterval? = nil
    var curve: Curve = .linear
    var settle: RunnerSettle = .idle
}

struct SwipeRequest: Codable, Sendable {
    enum Direction: String, Codable, Sendable {
        case up, down, left, right
    }

    var target: RunnerTarget = .foreground
    var direction: Direction
    var settle: RunnerSettle = .idle
}

struct PinchRequest: Codable, Sendable {
    var target: RunnerTarget = .foreground
    var scale: Double
    var velocity: Double
    var settle: RunnerSettle = .idle
}

struct TypeRequest: Codable, Sendable {
    var target: RunnerTarget = .foreground
    var text: String
    var settle: RunnerSettle = .idle
}

struct KeyRequest: Codable, Sendable {
    enum Key: String, Codable, Sendable {
        case search, selectAll, addressBar, enter, escape, backspace, tab
        case space, shiftTab, deleteForward, arrowUp, arrowDown, arrowLeft, arrowRight, copy, cut, paste, undo, redo
    }
    var key: Key
}

struct PressButtonRequest: Codable, Sendable {
    enum Button: String, Codable, Sendable {
        case home, lock, volumeUp, volumeDown
    }

    var button: Button
}

struct OpenAppRequest: Codable, Sendable {
    var bundleID: String
}

struct AlertActionRequest: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case accept, dismiss
    }

    var target: RunnerTarget = .springboard
    var action: Action
}

// MARK: - State responses

struct HealthResponse: Codable, Sendable {
    var status: String
    var version: Int
    var deviceModel: String
    var osVersion: String
}

struct AppStateResponse: Codable, Sendable {
    enum State: String, Codable, Sendable {
        case foreground, background, notRunning, unknown
    }

    /// Bundle ID of the app the runner last activated or observed in the
    /// foreground. Active-process lookup is isolated in RunnerAccessibility;
    /// callers must still tolerate missing identifiers on unsupported SDKs.
    var bundleID: String?
    var state: State
    var springboardForeground: Bool
}

struct TreeResponse: Codable, Sendable {
    /// XCTest debugDescription dump of the target app's accessibility
    /// hierarchy (WDA's `format=description` equivalent). Structured JSON
    /// trees are a v2 addition.
    var target: RunnerTarget
    var tree: String
}

struct AlertInfo: Codable, Sendable, Hashable {
    var title: String
    var buttonLabels: [String]
}

struct AlertsResponse: Codable, Sendable {
    var target: RunnerTarget
    var alerts: [AlertInfo]
}

struct LockedResponse: Codable, Sendable {
    /// Heuristic from SpringBoard state and lock-screen elements; documented
    /// as best-effort under public XCTest.
    var locked: Bool
}

struct ActionResponse: Codable, Sendable {
    var ok: Bool
    var error: RunnerErrorBody?
}

struct RunnerErrorBody: Codable, Sendable {
    enum Code: String, Codable, Sendable {
        case notHittable
        case elementNotFound
        case snapshotFailed
        case alertBlocking
        case unsupported
        case internalError
    }

    var code: Code
    var message: String
}

// MARK: - Mac-side seam

/// The Mac-side client seam. `RunnerClient` conforms to this; integration
/// code (RunnerDeviceHost, RunnerOracle) depends only on the protocol so the
/// client, tests, and consumers can be built independently. `screenshot`
/// returns PNG bytes; every throwing method surfaces RunnerErrorBody codes.
protocol PhoneRunnerServing: Sendable {
    func health() async throws -> HealthResponse
    func tap(_ request: TapRequest) async throws
    func drag(_ request: DragRequest) async throws
    func swipe(_ request: SwipeRequest) async throws
    func pinch(_ request: PinchRequest) async throws
    func type(_ request: TypeRequest) async throws
    func pressKey(_ request: KeyRequest) async throws
    func pressButton(_ request: PressButtonRequest) async throws
    func openApp(_ request: OpenAppRequest) async throws
    func performAlertAction(_ request: AlertActionRequest) async throws
    func appState(target: RunnerTarget) async throws -> AppStateResponse
    func tree(target: RunnerTarget, maxDepth: Int?) async throws -> TreeResponse
    func alerts(target: RunnerTarget) async throws -> AlertsResponse
    func locked() async throws -> LockedResponse
    func screenshot() async throws -> Data
}
