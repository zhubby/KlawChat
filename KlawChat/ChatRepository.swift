import Foundation

protocol ChatRepositoryProtocol {
    var frames: AsyncStream<ServerFrame> { get }
    var settings: GatewaySettings { get }

    func save(settings: GatewaySettings)
    func connect(settings: GatewaySettings) async throws
    func disconnect()
    func bootstrap() async throws -> String
    func listProviders() async throws
    func createSession() async throws
    func updateSession(sessionKey: String, title: String, modelProvider: String?, model: String?) async throws
    func deleteSession(sessionKey: String) async throws
    func subscribe(sessionKey: String) async throws
    func loadHistory(sessionKey: String, beforeMessageID: String?, limit: Int) async throws
    func submit(
        sessionKey: String,
        input: String,
        stream: Bool,
        route: ModelRoute,
        attachments: [ArchiveAttachment]
    ) async throws
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

    func bootstrap() async throws -> String {
        try await client.send(method: "workspace.bootstrap", params: [:])
    }

    func listProviders() async throws {
        _ = try await client.send(method: "provider.list", params: [:])
    }

    func createSession() async throws {
        _ = try await client.send(method: "session.create", params: [:])
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
        _ = try await client.send(method: "session.update", params: params)
    }

    func deleteSession(sessionKey: String) async throws {
        _ = try await client.send(method: "session.delete", params: [
            "session_key": .string(sessionKey)
        ])
    }

    func subscribe(sessionKey: String) async throws {
        _ = try await client.send(method: "session.subscribe", params: [
            "session_key": .string(sessionKey)
        ])
    }

    func loadHistory(sessionKey: String, beforeMessageID: String?, limit: Int = 30) async throws {
        _ = try await client.send(method: "session.history.load", params: [
            "session_key": .string(sessionKey),
            "before_message_id": beforeMessageID.map(JSONValue.string) ?? .null,
            "limit": .number(Double(limit))
        ])
    }

    func submit(
        sessionKey: String,
        input: String,
        stream: Bool,
        route: ModelRoute,
        attachments: [ArchiveAttachment] = []
    ) async throws {
        var params: [String: JSONValue] = [
            "session_key": .string(sessionKey),
            "chat_id": .string(sessionKey),
            "input": .string(input),
            "stream": .bool(stream),
            "model_provider": .string(route.provider),
            "model": .string(route.model)
        ]
        if let firstAttachment = attachments.first {
            params["archive_id"] = .string(firstAttachment.archiveID)
        }
        if !attachments.isEmpty {
            params["attachments"] = .array(attachments.map(\.jsonValue))
        }
        _ = try await client.send(method: "session.submit", params: params)
    }
}

private extension ArchiveAttachment {
    var jsonValue: JSONValue {
        .object([
            "archive_id": .string(archiveID),
            "filename": filename.map(JSONValue.string) ?? .null,
            "mime_type": mimeType.map(JSONValue.string) ?? .null,
            "size_bytes": .number(Double(sizeBytes))
        ])
    }
}
