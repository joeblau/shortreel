import Foundation

// swiftc -swift-version 6 PhoneRunnerShared/PhoneRunnerProtocol.swift ShortReel/Services/PhoneRunner/RunnerClient.swift Tests/RunnerClientTests.swift -o /tmp/sr-client-tests
@main
enum RunnerClientTests {
    static func main() async throws {
        let client = RunnerClient(baseURL: URL(string: "http://127.0.0.1:18701")!) { request in
            precondition(request.url?.path == "/action/key")
            precondition(request.url?.port == 18701)
            precondition(request.httpMethod == "POST")
            let key = try JSONDecoder().decode(KeyRequest.self, from: request.httpBody!)
            precondition(key.key == .addressBar)
            return response(request, json: #"{"ok":true}"#)
        }
        try await client.pressKey(.init(key: .addressBar))
        for body in [#"{"ok":false}"#, #"{"ok":false,"error":{"code":"unsupported","message":"Cannot type"}}"#,
                     #"{"ok":true,"error":{"code":"internalError","message":"Contradictory response"}}"#] {
            let failed = RunnerClient(baseURL: URL(string: "http://127.0.0.1:18700")!) { request in
                response(request, json: body)
            }
            do {
                try await failed.pressKey(.init(key: .enter))
                preconditionFailure("Rejected action was reported as successful")
            } catch RunnerClientError.server { }
        }
        let health = RunnerClient(baseURL: URL(string: "http://127.0.0.1:18700")!) { request in
            precondition(request.timeoutInterval == 3)
            return response(request, json: "{}", status: 503)
        }
        do {
            _ = try await health.health()
            preconditionFailure("Non-success health response was accepted")
        } catch RunnerClientError.badStatus(let status, _) { precondition(status == 503) }
        print("Runner client tests passed")
    }

    private static func response(_ request: URLRequest, json: String, status: Int = 200) -> (Data, HTTPURLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
