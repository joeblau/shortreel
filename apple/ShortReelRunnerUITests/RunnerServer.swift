import FlyingFox
import FlyingSocks
import Foundation

/// FlyingFox server exposing the PhoneRunnerProtocol endpoints. The actor
/// serializes requests (UI actions must not interleave); all XCTest work hops
/// to `RunnerExecutor` on the main actor.
actor RunnerServer {
    private let server: HTTPServer
    private let executor = RunnerExecutor()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var serverTask: Task<Void, Error>?

    init() {
        // IPv4 loopback only: the Mac reaches the runner through the go-ios
        // userspace tunnel's forwarded localhost port; nothing on the LAN
        // should be able to drive the phone.
        let address = (try? sockaddr_in.inet(ip4: "127.0.0.1", port: PhoneRunnerProtocol.port))
            ?? sockaddr_in.inet(port: PhoneRunnerProtocol.port)
        server = HTTPServer(address: address)
    }

    func start() async throws {
        await registerRoutes()
        let server = server
        serverTask = Task {
            try await server.run()
        }
        for _ in 0 ..< 100 {
            if await server.listeningAddress != nil { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw RunnerFailure(.internalError, "Server failed to bind 127.0.0.1:\(PhoneRunnerProtocol.port)")
    }

    // MARK: - Routes

    private func registerRoutes() async {
        await server.appendRoute(HTTPRoute(method: .GET, path: PhoneRunnerProtocol.healthPath)) { [self] _ in
            await json(await executor.health())
        }
        await server.appendRoute(HTTPRoute(method: .POST, path: PhoneRunnerProtocol.tapPath)) { [self] request in
            await handleAction(request, as: TapRequest.self) { try await executor.tap($0) }
        }
        await server.appendRoute(HTTPRoute(method: .POST, path: PhoneRunnerProtocol.dragPath)) { [self] request in
            await handleAction(request, as: DragRequest.self) { try await executor.drag($0) }
        }
        await server.appendRoute(HTTPRoute(method: .POST, path: PhoneRunnerProtocol.swipePath)) { [self] request in
            await handleAction(request, as: SwipeRequest.self) { try await executor.swipe($0) }
        }
        await server.appendRoute(HTTPRoute(method: .POST, path: PhoneRunnerProtocol.pinchPath)) { [self] request in
            await handleAction(request, as: PinchRequest.self) { try await executor.pinch($0) }
        }
        await server.appendRoute(HTTPRoute(method: .POST, path: PhoneRunnerProtocol.typePath)) { [self] request in
            await handleAction(request, as: TypeRequest.self) { try await executor.type($0) }
        }
        await server.appendRoute(HTTPRoute(method: .POST, path: PhoneRunnerProtocol.keyPath)) { [self] request in
            await handleAction(request, as: KeyRequest.self) { try await executor.pressKey($0) }
        }
        await server.appendRoute(HTTPRoute(method: .POST, path: PhoneRunnerProtocol.pressButtonPath)) { [self] request in
            await handleAction(request, as: PressButtonRequest.self) { try await executor.pressButton($0) }
        }
        await server.appendRoute(HTTPRoute(method: .POST, path: PhoneRunnerProtocol.openAppPath)) { [self] request in
            await handleAction(request, as: OpenAppRequest.self) { try await executor.openApp($0) }
        }
        await server.appendRoute(HTTPRoute(method: .POST, path: PhoneRunnerProtocol.alertActionPath)) { [self] request in
            await handleAction(request, as: AlertActionRequest.self) { try await executor.performAlertAction($0) }
        }
        await server.appendRoute(HTTPRoute(method: .GET, path: PhoneRunnerProtocol.appStatePath)) { [self] request in
            await handleState(request) { target, _ in
                try await executor.appState(target: target)
            }
        }
        await server.appendRoute(HTTPRoute(method: .GET, path: PhoneRunnerProtocol.treePath)) { [self] request in
            await handleState(request) { target, request in
                try await executor.tree(target: target, maxDepth: request.query["maxDepth"].flatMap(Int.init))
            }
        }
        await server.appendRoute(HTTPRoute(method: .GET, path: PhoneRunnerProtocol.alertsPath)) { [self] request in
            await handleState(request) { target, _ in
                try await executor.alerts(target: target)
            }
        }
        await server.appendRoute(HTTPRoute(method: .GET, path: PhoneRunnerProtocol.lockedPath)) { [self] _ in
            await json(await executor.locked())
        }
        await server.appendRoute(HTTPRoute(method: .GET, path: PhoneRunnerProtocol.screenshotPath)) { [executor] _ in
            HTTPResponse(
                statusCode: .ok,
                headers: [.contentType: "image/png"],
                body: await executor.screenshot()
            )
        }
    }

    // MARK: - Plumbing

    private func handleAction<Body: Decodable & Sendable>(
        _ httpRequest: HTTPRequest,
        as _: Body.Type,
        perform: @Sendable (Body) async throws -> Void
    ) async -> HTTPResponse {
        let body: Body
        do {
            body = try await decoder.decode(Body.self, from: httpRequest.bodyData)
        } catch {
            return json(
                RunnerErrorBody(code: .internalError, message: "Malformed request body: \(error.localizedDescription)"),
                status: .badRequest
            )
        }
        do {
            try await perform(body)
            return json(ActionResponse(ok: true, error: nil))
        } catch let failure as RunnerFailure {
            return json(ActionResponse(ok: false, error: failure.body))
        } catch {
            return json(ActionResponse(ok: false, error: RunnerErrorBody(code: .internalError, message: error.localizedDescription)))
        }
    }

    private func handleState<Response: Encodable & Sendable>(
        _ httpRequest: HTTPRequest,
        fetch: @Sendable (RunnerTarget, HTTPRequest) async throws -> Response
    ) async -> HTTPResponse {
        do {
            let target = try targetParam(of: httpRequest)
            return json(try await fetch(target, httpRequest))
        } catch let failure as RunnerFailure {
            return json(failure.body, status: .badRequest)
        } catch {
            return json(
                RunnerErrorBody(code: .internalError, message: error.localizedDescription),
                status: .internalServerError
            )
        }
    }

    private func targetParam(of request: HTTPRequest) throws -> RunnerTarget {
        guard let raw = request.query["target"] else { return .foreground }
        guard let target = RunnerTarget(rawValue: raw) else {
            throw RunnerFailure(.internalError, "Unknown target '\(raw)'")
        }
        return target
    }

    private func json<Value: Encodable>(_ value: Value, status: HTTPStatusCode = .ok) -> HTTPResponse {
        let data = (try? encoder.encode(value)) ?? Data()
        return HTTPResponse(statusCode: status, headers: [.contentType: "application/json"], body: data)
    }
}
