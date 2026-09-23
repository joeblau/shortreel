import Foundation

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

enum RunnerTarget: String, Codable, Sendable {
    case foreground
    case springboard
}

enum RunnerSettle: String, Codable, Sendable {
    case idle
    case animation
    case none
}

struct RunnerPoint: Codable, Sendable, Hashable {
    var x: Double
    var y: Double
}

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

    var bundleID: String?
    var state: State
    var springboardForeground: Bool
}

struct TreeResponse: Codable, Sendable {
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
