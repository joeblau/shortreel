import Foundation

enum RunnerClientError: Error, LocalizedError {
    case server(RunnerErrorBody)
    case badStatus(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .server(let body): "\(body.code.rawValue): \(body.message)"
        case .badStatus(let status, let body): "Runner returned HTTP \(status): \(body)"
        case .decoding(let message): message
        }
    }
}

struct RunnerClient: PhoneRunnerServing {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    let baseURL: URL
    private let transport: Transport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(baseURL: URL, transport: @escaping Transport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    init(baseURL: URL, session: URLSession = .shared) {
        self.init(baseURL: baseURL) { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RunnerClientError.badStatus(-1, "non-HTTP response")
            }
            return (data, http)
        }
    }

    init(port: UInt16 = PhoneRunnerProtocol.port, session: URLSession = .shared) {
        self.init(baseURL: URL(string: "http://127.0.0.1:\(port)")!, session: session)
    }

    func health() async throws -> HealthResponse {
        try await get(PhoneRunnerProtocol.healthPath)
    }

    func tap(_ request: TapRequest) async throws {
        try await postAction(PhoneRunnerProtocol.tapPath, body: request)
    }

    func drag(_ request: DragRequest) async throws {
        try await postAction(PhoneRunnerProtocol.dragPath, body: request)
    }

    func swipe(_ request: SwipeRequest) async throws {
        try await postAction(PhoneRunnerProtocol.swipePath, body: request)
    }

    func pinch(_ request: PinchRequest) async throws {
        try await postAction(PhoneRunnerProtocol.pinchPath, body: request)
    }

    func type(_ request: TypeRequest) async throws {
        try await postAction(PhoneRunnerProtocol.typePath, body: request)
    }

    func pressKey(_ request: KeyRequest) async throws {
        try await postAction(PhoneRunnerProtocol.keyPath, body: request)
    }

    func pressButton(_ request: PressButtonRequest) async throws {
        try await postAction(PhoneRunnerProtocol.pressButtonPath, body: request)
    }

    func openApp(_ request: OpenAppRequest) async throws {
        try await postAction(PhoneRunnerProtocol.openAppPath, body: request)
    }

    func performAlertAction(_ request: AlertActionRequest) async throws {
        try await postAction(PhoneRunnerProtocol.alertActionPath, body: request)
    }

    func appState(target: RunnerTarget) async throws -> AppStateResponse {
        try await get(PhoneRunnerProtocol.appStatePath, query: [URLQueryItem(name: "target", value: target.rawValue)])
    }

    func tree(target: RunnerTarget, maxDepth: Int?) async throws -> TreeResponse {
        var query = [URLQueryItem(name: "target", value: target.rawValue)]
        if let maxDepth {
            query.append(URLQueryItem(name: "maxDepth", value: String(maxDepth)))
        }
        return try await get(PhoneRunnerProtocol.treePath, query: query)
    }

    func alerts(target: RunnerTarget) async throws -> AlertsResponse {
        try await get(PhoneRunnerProtocol.alertsPath, query: [URLQueryItem(name: "target", value: target.rawValue)])
    }

    func locked() async throws -> LockedResponse {
        try await get(PhoneRunnerProtocol.lockedPath)
    }

    func screenshot() async throws -> Data {
        let (data, response) = try await send(request(path: PhoneRunnerProtocol.screenshotPath, method: "GET"))
        try validate(response, data: data)
        return data
    }

    private func get<Response: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Response {
        let (data, response) = try await send(request(path: path, method: "GET", query: query))
        try validate(response, data: data)
        return try decode(Response.self, from: data)
    }

    private func postAction<Body: Encodable>(_ path: String, body: Body) async throws {
        var urlRequest = request(path: path, method: "POST")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(body)
        let (data, response) = try await send(urlRequest)
        try validate(response, data: data)
        let actionResponse = try decode(ActionResponse.self, from: data)
        guard actionResponse.ok, actionResponse.error == nil else {
            let error = actionResponse.error ?? RunnerErrorBody(code: .internalError, message: "The runner rejected the action without an explanation.")
            throw RunnerClientError.server(error)
        }
    }

    private func request(path: String, method: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = path == PhoneRunnerProtocol.healthPath ? 3 : 45
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await transport(request)
    }

    private func validate(_ response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            if let body = try? decoder.decode(RunnerErrorBody.self, from: data) {
                throw RunnerClientError.server(body)
            }
            throw RunnerClientError.badStatus(response.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw RunnerClientError.decoding("Failed to decode \(Response.self): \(error.localizedDescription)")
        }
    }
}
