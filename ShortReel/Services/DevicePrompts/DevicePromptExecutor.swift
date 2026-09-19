import Foundation

/// Converts validated intent into input on one specific Bluetooth phone.
@MainActor
enum DevicePromptExecutor {
    static func perform(_ action: PhonePromptAction, using host: any DeviceHost, on device: DeviceDescriptor) async throws {
        try Task.checkCancellation()
        switch action {
        case .home:
            try await host.pressKey(.home, on: device)
        case .openApp(let name):
            try await search(name, using: host, on: device)
            try await Task.sleep(for: .milliseconds(600))
            try await host.pressKey(.enter, on: device)
            try await Task.sleep(for: .milliseconds(500))
        case .search(let query):
            try await search(query, using: host, on: device)
        case .typeText(let text):
            try await host.type(text, on: device)
        case .tap(let x, let y):
            guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                throw PhonePromptPlanningError.needsClarification("Tap coordinates must be between 0% and 100%.")
            }
            try await host.tap(NormalizedPoint(x: x, y: y), on: device)
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
            }
            try await host.pressKey(deviceKey, on: device)
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    private static func search(_ text: String, using host: any DeviceHost, on device: DeviceDescriptor) async throws {
        // Home makes Command-Space consistently open a fresh system Search.
        try await host.pressKey(.home, on: device)
        try await Task.sleep(for: .milliseconds(200))
        try await host.pressKey(.search, on: device)
        try await Task.sleep(for: .milliseconds(400))
        try await host.pressKey(.selectAll, on: device)
        try await host.type(text, on: device)
    }
}
