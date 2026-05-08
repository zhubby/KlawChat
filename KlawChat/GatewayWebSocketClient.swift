import Foundation
import Starscream

enum GatewayWebSocketConnectionEvent: Equatable, Sendable {
    case connecting
    case connected
    case reconnecting
    case reconnected
    case disconnected
    case failed(String)
}

protocol GatewayWebSocketClientProtocol: AnyObject {
    var frames: AsyncStream<ServerFrame> { get }
    var connectionEvents: AsyncStream<GatewayWebSocketConnectionEvent> { get }
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

final class StarscreamGatewayWebSocketClient: NSObject, GatewayWebSocketClientProtocol {
    private static let connectionTimeoutNanoseconds: UInt64 = 5_000_000_000
    private static let reconnectDelaysNanoseconds: [UInt64] = [
        500_000_000,
        1_000_000_000,
        2_000_000_000,
        5_000_000_000,
        10_000_000_000
    ]

    private var socket: WebSocket?
    private var currentRequest: URLRequest?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var frameContinuation: AsyncStream<ServerFrame>.Continuation?
    private var connectionEventContinuation: AsyncStream<GatewayWebSocketConnectionEvent>.Continuation?
    private var pendingResults: [String: CheckedContinuation<[String: JSONValue], Error>] = [:]
    private var pendingTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var isConnected = false
    private var isManuallyDisconnecting = false
    private var hasEstablishedConnection = false
    private var reconnectAttempt = 0
    private var pendingConnectedEvent: GatewayWebSocketConnectionEvent = .connected

    lazy var frames: AsyncStream<ServerFrame> = AsyncStream { continuation in
        self.frameContinuation = continuation
    }

    lazy var connectionEvents: AsyncStream<GatewayWebSocketConnectionEvent> = AsyncStream { continuation in
        self.connectionEventContinuation = continuation
    }

    func connect(baseURLString: String, token: String?) async throws {
        disconnect(emitEvent: false)
        guard let url = websocketURL(from: baseURLString) else {
            throw GatewayWebSocketError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if let token = token?.nilIfBlank {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        currentRequest = request
        isManuallyDisconnecting = false
        hasEstablishedConnection = false
        reconnectAttempt = 0
        connectionEventContinuation?.yield(.connecting)

        try await withCheckedThrowingContinuation { continuation in
            connectContinuation = continuation
            connectTimeoutTask?.cancel()
            connectTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.connectionTimeoutNanoseconds)
                self?.resumeConnectContinuation(throwing: GatewayWebSocketError.requestTimedOut)
                self?.socket?.disconnect(closeCode: CloseCode.goingAway.rawValue)
            }
            openSocket(successEvent: .connected)
        }
    }

    func disconnect() {
        disconnect(emitEvent: true)
    }

    func send(method: String, params: [String: JSONValue]) async throws -> String {
        guard let socket, isConnected else { throw GatewayWebSocketError.notConnected }
        let id = UUID().uuidString
        let text = try encodedFrameText(id: id, method: method, params: params)
        await write(text, using: socket)
        return id
    }

    func sendNotification(method: String, params: [String: JSONValue]) async throws {
        guard let socket, isConnected else { throw GatewayWebSocketError.notConnected }
        let text = try encodedNotificationText(method: method, params: params)
        await write(text, using: socket)
    }

    func sendAndWaitResult(
        method: String,
        params: [String: JSONValue],
        timeoutNanoseconds: UInt64
    ) async throws -> [String: JSONValue] {
        guard let socket, isConnected else { throw GatewayWebSocketError.notConnected }
        let id = UUID().uuidString
        let text = try encodedFrameText(id: id, method: method, params: params)

        return try await withCheckedThrowingContinuation { continuation in
            pendingResults[id] = continuation
            pendingTimeoutTasks[id] = Task { [weak self, id] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                self?.resumePendingResult(id, throwing: GatewayWebSocketError.requestTimedOut)
            }
            socket.write(string: text)
        }
    }

    private func disconnect(emitEvent: Bool) {
        isManuallyDisconnecting = true
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        pendingTimeoutTasks.values.forEach { $0.cancel() }
        pendingTimeoutTasks.removeAll()
        socket?.delegate = nil
        socket?.disconnect(closeCode: CloseCode.goingAway.rawValue)
        socket = nil
        isConnected = false
        resumeConnectContinuation(throwing: GatewayWebSocketError.notConnected)
        resumeAllPendingResults(throwing: GatewayWebSocketError.notConnected)
        if emitEvent {
            connectionEventContinuation?.yield(.disconnected)
        }
    }

    private func openSocket(successEvent: GatewayWebSocketConnectionEvent) {
        guard let currentRequest else {
            resumeConnectContinuation(throwing: GatewayWebSocketError.invalidBaseURL)
            return
        }

        pendingConnectedEvent = successEvent
        let socket = WebSocket(request: currentRequest)
        socket.callbackQueue = .main
        socket.delegate = self
        socket.respondToPingWithPong = true
        self.socket = socket
        socket.connect()
    }

    private func write(_ text: String, using socket: WebSocket) async {
        await withCheckedContinuation { continuation in
            socket.write(string: text) {
                continuation.resume()
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
        frameContinuation?.yield(frame)
    }

    private func handle(text: String) {
        do {
            let frame = try decoder.decode(ServerFrame.self, from: Data(text.utf8))
            handle(frame)
        } catch {
            frameContinuation?.yield(.error(
                id: nil,
                error: ServerErrorFrame(
                    code: "invalid_json",
                    message: "Failed to decode gateway websocket frame.",
                    data: .object(["retryable": .bool(false)])
                )
            ))
        }
    }

    private func handleTransportClosed(reason: String) {
        isConnected = false
        socket?.delegate = nil
        socket = nil
        resumeAllPendingResults(throwing: GatewayWebSocketError.notConnected)

        if isManuallyDisconnecting {
            connectionEventContinuation?.yield(.disconnected)
            return
        }

        if hasEstablishedConnection {
            reconnectTask = nil
            scheduleReconnect()
        } else {
            resumeConnectContinuation(throwing: GatewayWebSocketError.notConnected)
            connectionEventContinuation?.yield(.failed(reason))
        }
    }

    private func handleTransportError(_ error: Error?) {
        let message = error?.localizedDescription ?? "WebSocket connection failed."
        isConnected = false
        socket?.delegate = nil
        socket = nil
        resumeAllPendingResults(throwing: GatewayWebSocketError.notConnected)

        if isManuallyDisconnecting {
            connectionEventContinuation?.yield(.disconnected)
            return
        }

        if isPermanentConnectionFailure(message) {
            resumeConnectContinuation(throwing: GatewayWebSocketError.serverError(message))
            connectionEventContinuation?.yield(.failed(message))
            return
        }

        if hasEstablishedConnection {
            reconnectTask = nil
            scheduleReconnect()
        } else {
            resumeConnectContinuation(throwing: GatewayWebSocketError.serverError(message))
            connectionEventContinuation?.yield(.failed(message))
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, currentRequest != nil else { return }
        connectionEventContinuation?.yield(.reconnecting)
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.reconnectDelayNanoseconds()
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            self.reconnectAttempt += 1
            self.openSocket(successEvent: .reconnected)
        }
    }

    private func reconnectDelayNanoseconds() -> UInt64 {
        let index = min(reconnectAttempt, Self.reconnectDelaysNanoseconds.count - 1)
        return Self.reconnectDelaysNanoseconds[index]
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
        pendingTimeoutTasks.removeValue(forKey: id)?.cancel()
        continuation.resume(returning: result)
        return true
    }

    @discardableResult
    private func resumePendingResult(_ id: String, throwing error: Error) -> Bool {
        guard let continuation = pendingResults.removeValue(forKey: id) else {
            return false
        }
        pendingTimeoutTasks.removeValue(forKey: id)?.cancel()
        continuation.resume(throwing: error)
        return true
    }

    private func resumeAllPendingResults(throwing error: Error) {
        let continuations = Array(pendingResults.values)
        pendingResults.removeAll()
        pendingTimeoutTasks.values.forEach { $0.cancel() }
        pendingTimeoutTasks.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func resumeConnectContinuation(throwing error: Error) {
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        continuation.resume(throwing: error)
    }

    private func resumeConnectContinuation() {
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        continuation.resume()
    }

    private func isPermanentConnectionFailure(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("401")
            || lowercased.contains("403")
            || lowercased.contains("unauthorized")
            || lowercased.contains("forbidden")
            || lowercased.contains("permission")
            || lowercased.contains("auth")
    }

    private func websocketURL(from baseURLString: String) -> URL? {
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

extension StarscreamGatewayWebSocketClient: WebSocketDelegate {
    func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        switch event {
        case .connected:
            isConnected = true
            hasEstablishedConnection = true
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            resumeConnectContinuation()
            connectionEventContinuation?.yield(pendingConnectedEvent)
        case .disconnected(let reason, _):
            handleTransportClosed(reason: reason)
        case .text(let string):
            handle(text: string)
        case .binary:
            frameContinuation?.yield(.error(
                id: nil,
                error: ServerErrorFrame(
                    code: "invalid_request",
                    message: "Gateway WebSocket v1 does not accept binary frames.",
                    data: .object(["retryable": .bool(false)])
                )
            ))
        case .ping, .pong, .viabilityChanged:
            break
        case .reconnectSuggested(let shouldReconnect):
            if shouldReconnect, hasEstablishedConnection, !isManuallyDisconnecting {
                scheduleReconnect()
            }
        case .cancelled, .peerClosed:
            handleTransportClosed(reason: "WebSocket connection closed.")
        case .error(let error):
            handleTransportError(error)
        }
    }
}
