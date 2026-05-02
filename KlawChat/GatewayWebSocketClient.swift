import Foundation

protocol GatewayWebSocketClientProtocol: AnyObject {
    var frames: AsyncStream<ServerFrame> { get }
    func connect(baseURLString: String, token: String?) async throws
    func disconnect()
    func send(method: String, params: [String: JSONValue]) async throws -> String
}

enum GatewayWebSocketError: LocalizedError {
    case invalidBaseURL
    case notConnected
    case encodingFailed
    case decodingFailed

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
        }
    }
}

final class URLSessionGatewayWebSocketClient: GatewayWebSocketClientProtocol {
    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var continuation: AsyncStream<ServerFrame>.Continuation?

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

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop(task)
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    func send(method: String, params: [String: JSONValue]) async throws -> String {
        guard let task else { throw GatewayWebSocketError.notConnected }
        let id = UUID().uuidString
        let frame = ClientMethodFrame(id: id, method: method, params: params)
        guard let data = try? encoder.encode(frame),
              let text = String(data: data, encoding: .utf8) else {
            throw GatewayWebSocketError.encodingFailed
        }
        try await task.send(.string(text))
        return id
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { result in
            Task { @MainActor [weak self, task] in
                guard let self, self.task === task else { return }
                switch result {
                case .success(let message):
                    if let frame = self.decode(message) {
                        self.continuation?.yield(frame)
                    }
                    self.receiveLoop(task)
                case .failure(let error):
                    self.continuation?.yield(.error(
                        id: nil,
                        error: ServerErrorFrame(code: "websocket_receive_failed", message: error.localizedDescription, data: nil)
                    ))
                }
            }
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
        components.queryItems = token?.nilIfBlank.map { [URLQueryItem(name: "token", value: $0)] }
        return components.url
    }
}
