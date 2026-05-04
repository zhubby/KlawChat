import Foundation

protocol GatewayWebSocketClientProtocol: AnyObject {
    var frames: AsyncStream<ServerFrame> { get }
    func connect(baseURLString: String, token: String?) async throws
    func disconnect()
    func send(method: String, params: [String: JSONValue]) async throws -> String
    func sendNotification(method: String, params: [String: JSONValue]) async throws
    func sendAndWaitResult(method: String, params: [String: JSONValue], timeoutNanoseconds: UInt64) async throws -> [String: JSONValue]
}

enum GatewayWebSocketError: LocalizedError {
    case invalidBaseURL
    case notConnected
    case encodingFailed
    case decodingFailed
    case requestTimedOut
    case serverError(String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Gateway URL is invalid."
        case .notConnected:
            return "WebSocket is not connected."
        case .encodingFailed:
            return "Failed to encode WebSocket request."
        case .decodingFailed:
            return "Failed to decode WebSocket response."
        case .requestTimedOut:
            return "Gateway request timed out."
        case .serverError(let message):
            return message
        case .unexpectedResponse:
            return "Gateway returned an unexpected response."
        }
    }
}

final class URLSessionGatewayWebSocketClient: GatewayWebSocketClientProtocol {
    private static let gatewayMaximumTextFrameBytes = 16 * 1_024 * 1_024

    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var continuation: AsyncStream<ServerFrame>.Continuation?
    private var pendingResults: [String: CheckedContinuation<[String: JSONValue], Error>] = [:]

    lazy var frames: AsyncStream<ServerFrame> = AsyncStream { continuation in
        self.continuation = continuation
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(baseURLString: String, token: String?) async throws {
        disconnect()
        guard let url = websocketURL(from: baseURLString, token: token) else {
            throw GatewayWebSocketError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        if let token = token?.nilIfBlank {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.gatewayMaximumTextFrameBytes
        self.task = task
        task.resume()
        receiveLoop(task)
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        resumeAllPendingResults(throwing: GatewayWebSocketError.notConnected)
    }

    func send(method: String, params: [String: JSONValue]) async throws -> String {
        guard let task else { throw GatewayWebSocketError.notConnected }
        let id = UUID().uuidString
        let text = try encodedFrameText(id: id, method: method, params: params)
        try await task.send(.string(text))
        return id
    }

    func sendNotification(method: String, params: [String: JSONValue]) async throws {
        guard let task else { throw GatewayWebSocketError.notConnected }
        let text = try encodedNotificationText(method: method, params: params)
        try await task.send(.string(text))
    }

    func sendAndWaitResult(
        method: String,
        params: [String: JSONValue],
        timeoutNanoseconds: UInt64
    ) async throws -> [String: JSONValue] {
        guard let task else { throw GatewayWebSocketError.notConnected }
        let id = UUID().uuidString
        let text = try encodedFrameText(id: id, method: method, params: params)

        return try await withCheckedThrowingContinuation { continuation in
            pendingResults[id] = continuation

            Task { @MainActor [weak self, task, text, id] in
                do {
                    try await task.send(.string(text))
                } catch {
                    self?.resumePendingResult(id, throwing: error)
                }
            }

            Task { @MainActor [weak self, id] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                self?.resumePendingResult(id, throwing: GatewayWebSocketError.requestTimedOut)
            }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { result in
            Task { @MainActor [weak self, task] in
                guard let self, self.task === task else { return }
                switch result {
                case .success(let message):
                    if let frame = self.decode(message) {
                        self.handle(frame)
                    }
                    self.receiveLoop(task)
                case .failure(let error):
                    self.resumeAllPendingResults(throwing: error)
                    self.continuation?.yield(.error(
                        id: nil,
                        error: ServerErrorFrame(code: "websocket_receive_failed", message: error.localizedDescription, data: nil)
                    ))
                }
            }
        }
    }

    private func handle(_ frame: ServerFrame) {
        switch frame {
        case .result(let id, let result):
            if resumePendingResult(id, returning: result) {
                return
            }
        case .error(let id, let error):
            if let id, resumePendingResult(id, throwing: GatewayWebSocketError.serverError(error.message)) {
                return
            }
        case .notification, .serverRequest:
            break
        }
        continuation?.yield(frame)
    }

    private func encodedFrameText(id: String, method: String, params: [String: JSONValue]) throws -> String {
        let frame = ClientMethodFrame(id: id, method: method, params: params)
        guard let data = try? encoder.encode(frame),
              let text = String(data: data, encoding: .utf8) else {
            throw GatewayWebSocketError.encodingFailed
        }
        return text
    }

    private func encodedNotificationText(method: String, params: [String: JSONValue]) throws -> String {
        let frame = ClientNotificationFrame(method: method, params: params)
        guard let data = try? encoder.encode(frame),
              let text = String(data: data, encoding: .utf8) else {
            throw GatewayWebSocketError.encodingFailed
        }
        return text
    }

    @discardableResult
    private func resumePendingResult(_ id: String, returning result: [String: JSONValue]) -> Bool {
        guard let continuation = pendingResults.removeValue(forKey: id) else {
            return false
        }
        continuation.resume(returning: result)
        return true
    }

    @discardableResult
    private func resumePendingResult(_ id: String, throwing error: Error) -> Bool {
        guard let continuation = pendingResults.removeValue(forKey: id) else {
            return false
        }
        continuation.resume(throwing: error)
        return true
    }

    private func resumeAllPendingResults(throwing error: Error) {
        let continuations = Array(pendingResults.values)
        pendingResults.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func decode(_ message: URLSessionWebSocketTask.Message) -> ServerFrame? {
        switch message {
        case .string(let text):
            return try? decoder.decode(ServerFrame.self, from: Data(text.utf8))
        case .data(let data):
            return try? decoder.decode(ServerFrame.self, from: data)
        @unknown default:
            return nil
        }
    }

    private func websocketURL(from baseURLString: String, token: String?) -> URL? {
        guard var components = URLComponents(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        if components.scheme == nil {
            components.scheme = "http"
        }
        switch components.scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            break
        }
        components.path = "/ws/chat"
        components.queryItems = nil
        return components.url
    }
}
