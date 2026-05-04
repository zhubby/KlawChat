import Foundation

protocol ChatRepositoryProtocol {
    var frames: AsyncStream<ServerFrame> { get }
    var settings: GatewaySettings { get }

    func save(settings: GatewaySettings)
    func connect(settings: GatewaySettings) async throws
    func disconnect()
    func initialize() async throws
    func bootstrap() async throws -> [String: JSONValue]
    func listProviders() async throws -> [String: JSONValue]
    func createSession() async throws
    func updateSession(sessionKey: String, title: String, modelProvider: String?, model: String?) async throws
    func deleteSession(sessionKey: String) async throws
    func subscribe(sessionKey: String) async throws
    func loadHistory(sessionKey: String, beforeMessageID: String?, limit: Int) async throws -> [String: JSONValue]
    func submit(
        sessionKey: String,
        input: String,
        stream: Bool,
        route: ModelRoute,
        attachments: [ArchiveAttachment]
    ) async throws
    func cancelTurn(sessionKey: String, threadID: String, turnID: String) async throws
    func respondToApproval(requestID: String, threadID: String, turnID: String, decision: String) async throws
    func respondToTool(requestID: String, threadID: String, turnID: String, result: [String: JSONValue]) async throws
    func respondToUserInput(requestID: String, threadID: String, turnID: String, input: String) async throws
}

final class ChatRepository: ChatRepositoryProtocol {
    private let client: GatewayWebSocketClientProtocol
    private let settingsStore: GatewaySettingsStore

    var frames: AsyncStream<ServerFrame> { client.frames }
    private(set) var settings: GatewaySettings

    init(client: GatewayWebSocketClientProtocol, settingsStore: GatewaySettingsStore) {
        self.client = client
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
    }

    func save(settings: GatewaySettings) {
        self.settings = settings
        settingsStore.save(settings)
    }

    func connect(settings: GatewaySettings) async throws {
        save(settings: settings)
        try await client.connect(baseURLString: settings.baseURLString, token: settings.token)
    }

    func disconnect() {
        client.disconnect()
    }

    func initialize() async throws {
        let result = try await client.sendAndWaitResult(
            method: "initialize",
            params: [
                "client_info": .object([
                    "name": .string("klaw-ios"),
                    "title": .string("KlawChat"),
                    "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
                ]),
                "capabilities": .object([
                    "protocol_version": .string("v1"),
                    "turns": .bool(true),
                    "items": .bool(true),
                    "tools": .bool(true),
                    "approvals": .bool(true),
                    "server_requests": .bool(true),
                    "cancellation": .bool(true),
                    "schema": .bool(false)
                ])
            ],
            timeoutNanoseconds: 5_000_000_000
        )
        guard result.string("protocol_version") == "v1" else {
            throw GatewayWebSocketError.unexpectedResponse
        }
        try await client.sendNotification(method: "initialized", params: [:])
    }

    func bootstrap() async throws -> [String: JSONValue] {
        try await client.sendAndWaitResult(
            method: "session/list",
            params: [:],
            timeoutNanoseconds: 5_000_000_000
        )
    }

    func listProviders() async throws -> [String: JSONValue] {
        try await client.sendAndWaitResult(
            method: "provider/list",
            params: [:],
            timeoutNanoseconds: 5_000_000_000
        )
    }

    func createSession() async throws {
        _ = try await client.send(method: "session/create", params: [:])
    }

    func updateSession(sessionKey: String, title: String, modelProvider: String?, model: String?) async throws {
        var params: [String: JSONValue] = [
            "session_key": .string(sessionKey),
            "title": .string(title)
        ]
        if let modelProvider = modelProvider?.nilIfBlank {
            params["model_provider"] = .string(modelProvider)
        }
        if let model = model?.nilIfBlank {
            params["model"] = .string(model)
        }
        _ = try await client.send(method: "session/update", params: params)
    }

    func deleteSession(sessionKey: String) async throws {
        _ = try await client.send(method: "session/delete", params: [
            "session_key": .string(sessionKey)
        ])
    }

    func subscribe(sessionKey: String) async throws {
        _ = try await client.send(method: "session/subscribe", params: [
            "session_key": .string(sessionKey)
        ])
    }

    func loadHistory(sessionKey: String, beforeMessageID: String?, limit: Int = 10) async throws -> [String: JSONValue] {
        try await client.sendAndWaitResult(
            method: "thread/history",
            params: [
                "session_key": .string(sessionKey),
                "before_message_id": beforeMessageID.map(JSONValue.string) ?? .null,
                "limit": .number(Double(limit))
            ],
            timeoutNanoseconds: 5_000_000_000
        )
    }

    func submit(
        sessionKey: String,
        input: String,
        stream: Bool,
        route: ModelRoute,
        attachments: [ArchiveAttachment] = []
    ) async throws {
        let turnID = "turn_\(UUID().uuidString)"
        let inputBlocks = [.object(["type": .string("text"), "text": .string(input)])]
            + attachments.map(\.contentBlock)
        let params: [String: JSONValue] = [
            "session_id": .string(sessionKey),
            "thread_id": .string(sessionKey),
            "turn_id": .string(turnID),
            "input": .array(inputBlocks),
            "stream": .bool(stream),
            "model_provider": .string(route.provider),
            "model": .string(route.model),
            "metadata": .object([:])
        ]
        _ = try await client.send(method: "turn/start", params: params)
    }

    func cancelTurn(sessionKey: String, threadID: String, turnID: String) async throws {
        _ = try await client.send(method: "turn/cancel", params: [
            "session_id": .string(sessionKey),
            "thread_id": .string(threadID),
            "turn_id": .string(turnID)
        ])
    }

    func respondToApproval(requestID: String, threadID: String, turnID: String, decision: String) async throws {
        _ = try await client.send(method: "approval/respond", params: [
            "request_id": .string(requestID),
            "thread_id": .string(threadID),
            "turn_id": .string(turnID),
            "decision": .string(decision)
        ])
    }

    func respondToTool(requestID: String, threadID: String, turnID: String, result: [String: JSONValue]) async throws {
        _ = try await client.send(method: "tool/respond", params: [
            "request_id": .string(requestID),
            "thread_id": .string(threadID),
            "turn_id": .string(turnID),
            "result": .object(result)
        ])
    }

    func respondToUserInput(requestID: String, threadID: String, turnID: String, input: String) async throws {
        _ = try await client.send(method: "user_input/respond", params: [
            "request_id": .string(requestID),
            "thread_id": .string(threadID),
            "turn_id": .string(turnID),
            "answers": .string(input)
        ])
    }
}

private extension ArchiveAttachment {
    var contentBlock: JSONValue {
        .object([
            "type": .string("attachment"),
            "archive_id": .string(archiveID),
            "filename": filename.map(JSONValue.string) ?? .null,
            "mime_type": mimeType.map(JSONValue.string) ?? .null,
            "size_bytes": .number(Double(sizeBytes))
        ])
    }
}
