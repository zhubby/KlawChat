import Foundation
import Testing
@testable import klaw

@MainActor
struct ChatViewModelTests {
    @Test func decodesSnakeCaseServerFrameTypes() throws {
        let json = """
        {
          "type": "result",
          "id": "request-1",
          "result": {
            "session_key": "s1",
            "has_more": false
          }
        }
        """

        let frame = try JSONDecoder().decode(ServerFrame.self, from: Data(json.utf8))

        #expect(frame == .result(id: "request-1", result: [
            "session_key": .string("s1"),
            "has_more": .bool(false)
        ]))
    }

    @Test func bootstrapResultSelectsAndSortsSessions() {
        let viewModel = ChatViewModel(repository: MockChatRepository())

        viewModel.apply(frame: .result(id: "1", result: [
            "sessions": .array([
                .object([
                    "session_key": .string("older"),
                    "title": .string("Older"),
                    "created_at_ms": .number(1)
                ]),
                .object([
                    "session_key": .string("newer"),
                    "title": .string("Newer"),
                    "created_at_ms": .number(2)
                ])
            ]),
            "active_session_key": .string("older")
        ]))

        #expect(viewModel.sessions.map(\.sessionKey) == ["newer", "older"])
        #expect(viewModel.selectedSessionKey == "older")
    }

    @Test func historyMessagesArePrependedAndDeduplicated() {
        let viewModel = ChatViewModel(repository: MockChatRepository())
        viewModel.apply(frame: .result(id: "bootstrap", result: [
            "sessions": .array([
                .object([
                    "session_key": .string("s1"),
                    "title": .string("Agent"),
                    "created_at_ms": .number(1)
                ])
            ])
        ]))
        viewModel.apply(frame: .event(event: "session.message", payload: [
            "session_key": .string("s1"),
            "role": .string("assistant"),
            "message_id": .string("m2"),
            "timestamp_ms": .number(2),
            "response": .object(["content": .string("new")])
        ]))

        viewModel.apply(frame: .result(id: "history", result: [
            "session_key": .string("s1"),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .string("old"),
                    "timestamp_ms": .number(1),
                    "message_id": .string("m1")
                ]),
                .object([
                    "role": .string("assistant"),
                    "content": .string("duplicate"),
                    "timestamp_ms": .number(2),
                    "message_id": .string("m2")
                ])
            ]),
            "has_more": .bool(false),
            "oldest_loaded_message_id": .string("m1")
        ]))

        #expect(viewModel.selectedMessages.map(\.text) == ["old", "new"])
    }

    @Test func streamDeltaUpdatesAssistantDraftAndDoneFinalizesIt() {
        let viewModel = ChatViewModel(repository: MockChatRepository())
        viewModel.apply(frame: .result(id: "bootstrap", result: [
            "sessions": .array([
                .object([
                    "session_key": .string("s1"),
                    "title": .string("Agent"),
                    "created_at_ms": .number(1)
                ])
            ])
        ]))

        viewModel.apply(frame: .event(event: "session.stream.delta", payload: [
            "session_key": .string("s1"),
            "delta": .string("Hel")
        ]))
        viewModel.apply(frame: .event(event: "session.stream.delta", payload: [
            "session_key": .string("s1"),
            "delta": .string("lo")
        ]))
        viewModel.apply(frame: .event(event: "session.stream.done", payload: [
            "session_key": .string("s1")
        ]))

        #expect(viewModel.selectedMessages.last?.text == "Hello")
        #expect(viewModel.selectedMessages.last?.isStreaming == false)
    }

    @Test func repeatedAssistantSessionMessagesForSameRequestUpdateOneBubble() {
        let viewModel = ChatViewModel(repository: MockChatRepository())
        viewModel.apply(frame: .result(id: "bootstrap", result: [
            "sessions": .array([
                .object([
                    "session_key": .string("s1"),
                    "title": .string("Agent"),
                    "created_at_ms": .number(1)
                ])
            ])
        ]))

        viewModel.apply(frame: .event(event: "session.message", payload: [
            "session_key": .string("s1"),
            "request_id": .string("r1"),
            "role": .string("assistant"),
            "response": .object(["content": .string("Hel")])
        ]))
        viewModel.apply(frame: .event(event: "session.message", payload: [
            "session_key": .string("s1"),
            "request_id": .string("r1"),
            "role": .string("assistant"),
            "response": .object(["content": .string("Hello")])
        ]))
        viewModel.apply(frame: .event(event: "session.stream.done", payload: [
            "session_key": .string("s1")
        ]))

        #expect(viewModel.selectedMessages.count == 1)
        #expect(viewModel.selectedMessages.first?.text == "Hello")
        #expect(viewModel.selectedMessages.first?.isStreaming == false)
    }

    @Test func createSessionShowsPendingStateAfterWorkspaceLoads() async {
        let repository = MockChatRepository()
        let viewModel = ChatViewModel(repository: repository)
        viewModel.apply(frame: .event(event: "session.connected", payload: [:]))
        viewModel.apply(frame: .result(id: "bootstrap", result: [
            "sessions": .array([])
        ]))

        viewModel.createSession()
        await Task.yield()

        #expect(repository.createdSessionRequestCount == 1)
        #expect(viewModel.isCreatingSession == true)
        #expect(viewModel.statusMessage == "Creating agent...")
    }

    @Test func createSessionResultClearsPendingState() {
        let viewModel = ChatViewModel(repository: MockChatRepository())
        viewModel.apply(frame: .event(event: "session.connected", payload: [:]))
        viewModel.apply(frame: .result(id: "bootstrap", result: [
            "sessions": .array([])
        ]))

        viewModel.createSession()
        viewModel.apply(frame: .result(id: "create", result: [
            "session_key": .string("s1"),
            "title": .string("Agent 1"),
            "created_at_ms": .number(10)
        ]))

        #expect(viewModel.isCreatingSession == false)
        #expect(viewModel.statusMessage == "Created Agent 1")
        #expect(viewModel.sessions.map(\.sessionKey) == ["s1"])
    }

    @Test func repositoryBuildsSubmitParams() async throws {
        let client = MockWebSocketClient()
        let repository = ChatRepository(
            client: client,
            settingsStore: MockSettingsStore()
        )

        try await repository.submit(
            sessionKey: "s1",
            input: "hello",
            stream: true,
            route: ModelRoute(provider: "anthropic", model: "claude-sonnet-4-5"),
            attachments: []
        )

        #expect(client.sentMethods == ["session.submit"])
        #expect(client.sentParams.first?["session_key"] == .string("s1"))
        #expect(client.sentParams.first?["chat_id"] == .string("s1"))
        #expect(client.sentParams.first?["input"] == .string("hello"))
        #expect(client.sentParams.first?["stream"] == .bool(true))
        #expect(client.sentParams.first?["model_provider"] == .string("anthropic"))
        #expect(client.sentParams.first?["model"] == .string("claude-sonnet-4-5"))
    }
}

private final class MockChatRepository: ChatRepositoryProtocol {
    var frames: AsyncStream<ServerFrame> { AsyncStream { _ in } }
    var settings = GatewaySettings.defaults
    var createdSessionRequestCount = 0

    func save(settings: GatewaySettings) {
        self.settings = settings
    }

    func connect(settings: GatewaySettings) async throws {}
    func disconnect() {}
    func bootstrap() async throws {}
    func listProviders() async throws {}
    func createSession() async throws {
        createdSessionRequestCount += 1
    }
    func updateSession(sessionKey: String, title: String, modelProvider: String?, model: String?) async throws {}
    func deleteSession(sessionKey: String) async throws {}
    func subscribe(sessionKey: String) async throws {}
    func loadHistory(sessionKey: String, beforeMessageID: String?, limit: Int) async throws {}
    func submit(sessionKey: String, input: String, stream: Bool, route: ModelRoute, attachments: [ArchiveAttachment]) async throws {}
}

private final class MockWebSocketClient: GatewayWebSocketClientProtocol {
    var frames: AsyncStream<ServerFrame> { AsyncStream { _ in } }
    var sentMethods: [String] = []
    var sentParams: [[String: JSONValue]] = []

    func connect(baseURLString: String, token: String?) async throws {}
    func disconnect() {}

    func send(method: String, params: [String: JSONValue]) async throws -> String {
        sentMethods.append(method)
        sentParams.append(params)
        return "request-id"
    }
}

private struct MockSettingsStore: GatewaySettingsStore {
    func load() -> GatewaySettings {
        .defaults
    }

    func save(_ settings: GatewaySettings) {}
}
