import Foundation
import Testing
@testable import KlawChat

@MainActor
struct ChatViewModelTests {
    @Test func chatMessageFormatsRelativeTimestamp() {
        let now = 1_000_000

        #expect(ChatMessage(role: .assistant, text: "", timestampMilliseconds: now).relativeTimestampText(nowMilliseconds: now) == "just now")
        #expect(ChatMessage(role: .assistant, text: "", timestampMilliseconds: now - 5_000).relativeTimestampText(nowMilliseconds: now) == "5 seconds ago")
        #expect(ChatMessage(role: .assistant, text: "", timestampMilliseconds: now - 60_000).relativeTimestampText(nowMilliseconds: now) == "1 minute ago")
        #expect(ChatMessage(role: .assistant, text: "", timestampMilliseconds: now - 7_200_000).relativeTimestampText(nowMilliseconds: now) == "2 hours ago")
        #expect(ChatMessage(role: .assistant, text: "", timestampMilliseconds: now - 172_800_000).relativeTimestampText(nowMilliseconds: now) == "2 days ago")
    }

    @Test func decodesV1ResultFrameWithoutType() throws {
        let json = """
        {
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

    @Test func decodesV1NotificationFrameWithoutID() throws {
        let json = """
        {
          "method": "item/agentMessage/delta",
          "params": {
            "session_id": "s1",
            "item_id": "i1",
            "delta": "hello"
          }
        }
        """

        let frame = try JSONDecoder().decode(ServerFrame.self, from: Data(json.utf8))

        #expect(frame == .notification(method: "item/agentMessage/delta", params: [
            "session_id": .string("s1"),
            "item_id": .string("i1"),
            "delta": .string("hello")
        ]))
    }

    @Test func decodesV1ServerRequestFrameWithIDAndMethod() throws {
        let json = """
        {
          "id": "srv-1",
          "method": "approval/request",
          "params": {
            "request_id": "srv-1",
            "thread_id": "s1",
            "turn_id": "t1",
            "scope": "turn",
            "prompt": "Allow command execution?"
          }
        }
        """

        let frame = try JSONDecoder().decode(ServerFrame.self, from: Data(json.utf8))

        #expect(frame == .serverRequest(id: "srv-1", method: "approval/request", params: [
            "request_id": .string("srv-1"),
            "thread_id": .string("s1"),
            "turn_id": .string("t1"),
            "scope": .string("turn"),
            "prompt": .string("Allow command execution?")
        ]))
    }

    @Test func encodesV1ClientRequestWithoutLegacyTypeField() throws {
        let frame = ClientMethodFrame(
            id: "req-1",
            method: "turn/start",
            params: ["stream": .bool(true)]
        )

        let object = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(frame))

        #expect(object["id"] == .string("req-1"))
        #expect(object["method"] == .string("turn/start"))
        #expect(object.object("params")?["stream"] == .bool(true))
        #expect(object["type"] == nil)
        #expect(object["jsonrpc"] == nil)
    }

    @Test func repositoryInitializeNegotiatesV1CapabilitiesAndSendsInitialized() async throws {
        let client = MockWebSocketClient()
        let repository = ChatRepository(client: client, settingsStore: MockSettingsStore())

        try await repository.initialize()

        #expect(client.sentMethods == ["initialize"])
        #expect(client.sentNotifications == ["initialized"])
        #expect(client.sentParams.first?.object("client_info")?.string("name") == "klaw-ios")
        #expect(client.sentParams.first?.object("capabilities")?.string("protocol_version") == "v1")
        #expect(client.sentParams.first?.object("capabilities")?.bool("server_requests") == true)
        #expect(client.sentParams.first?.object("capabilities")?.bool("schema") == false)
    }

    @Test func connectInitializesBeforeWorkspaceRequests() async {
        let repository = MockChatRepository()
        repository.settings.lastSessionKey = "older"
        let viewModel = ChatViewModel(repository: repository)

        viewModel.connect()
        await Task.yield()

        #expect(repository.initializeRequestCount == 1)
        #expect(repository.bootstrapRequestCount == 1)
        #expect(repository.providerListRequestCount == 1)
        #expect(viewModel.connectionState == .connected)
        #expect(viewModel.isWorkspaceLoaded == true)
        #expect(viewModel.selectedSessionKey == nil)
        #expect(repository.settings.lastSessionKey == nil)
    }

    @Test func bootstrapResultSortsSessionsWithoutAutoSelecting() {
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
        #expect(viewModel.selectedSessionKey == nil)
    }

    @Test func historyMessagesArePrependedAndDeduplicated() {
        let viewModel = ChatViewModel(repository: MockChatRepository())
        seedSession("s1", in: viewModel)
        viewModel.apply(frame: .notification(method: "item/completed", params: [
            "session_id": .string("s1"),
            "item": .object([
                "item_id": .string("m2"),
                "type": .string("agentMessage"),
                "status": .string("completed"),
                "payload": .object([
                    "response": .object(["content": .string("new")])
                ])
            ])
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

    @Test func v1AgentMessageDeltaUpdatesAssistantDraftAndTurnCompletedFinalizesIt() {
        let viewModel = ChatViewModel(repository: MockChatRepository())
        seedSession("s1", in: viewModel)

        viewModel.apply(frame: .notification(method: "item/agentMessage/delta", params: [
            "session_id": .string("s1"),
            "item_id": .string("i1"),
            "delta": .string("Hel")
        ]))
        viewModel.apply(frame: .notification(method: "item/agentMessage/delta", params: [
            "session_id": .string("s1"),
            "item_id": .string("i1"),
            "delta": .string("lo")
        ]))
        viewModel.apply(frame: .notification(method: "turn/completed", params: [
            "session_id": .string("s1"),
            "turn_id": .string("t1"),
            "status": .string("completed")
        ]))

        #expect(viewModel.selectedMessages.last?.text == "Hello")
        #expect(viewModel.selectedMessages.last?.isStreaming == false)
    }

    @Test func turnCompletedResponseCreatesAssistantMessageWhenItemCompletedIsAbsent() {
        let viewModel = ChatViewModel(repository: MockChatRepository())
        seedSession("s1", in: viewModel)

        viewModel.apply(frame: .notification(method: "turn/completed", params: [
            "session_id": .string("s1"),
            "turn_id": .string("t1"),
            "status": .string("completed"),
            "response": .object([
                "content": .string("Final answer"),
                "metadata": .object([:])
            ])
        ]))

        #expect(viewModel.selectedMessages.last?.role == .assistant)
        #expect(viewModel.selectedMessages.last?.text == "Final answer")
        #expect(viewModel.selectedMessages.last?.isStreaming == false)
    }

    @Test func itemCompletedForAgentMessageReplacesStreamedBubble() {
        let viewModel = ChatViewModel(repository: MockChatRepository())
        seedSession("s1", in: viewModel)

        viewModel.apply(frame: .notification(method: "item/agentMessage/delta", params: [
            "session_id": .string("s1"),
            "item_id": .string("i1"),
            "delta": .string("Hello")
        ]))
        viewModel.apply(frame: .notification(method: "item/completed", params: [
            "session_id": .string("s1"),
            "item": .object([
                "item_id": .string("i1"),
                "type": .string("agentMessage"),
                "status": .string("completed"),
                "payload": .object([
                    "response": .object([
                        "content": .string("Hello"),
                        "metadata": .object([:])
                    ])
                ])
            ])
        ]))

        #expect(viewModel.selectedMessages.count == 1)
        #expect(viewModel.selectedMessages.first?.text == "Hello")
        #expect(viewModel.selectedMessages.first?.messageID == "i1")
        #expect(viewModel.selectedMessages.first?.isStreaming == false)
    }

    @Test func interleavedAgentMessageDeltasAreMergedByItemID() {
        let viewModel = ChatViewModel(repository: MockChatRepository())
        seedSession("s1", in: viewModel)

        viewModel.apply(frame: .notification(method: "item/agentMessage/delta", params: [
            "session_id": .string("s1"),
            "item_id": .string("i1"),
            "delta": .string("A")
        ]))
        viewModel.apply(frame: .notification(method: "item/agentMessage/delta", params: [
            "session_id": .string("s1"),
            "item_id": .string("i2"),
            "delta": .string("B")
        ]))
        viewModel.apply(frame: .notification(method: "item/agentMessage/delta", params: [
            "session_id": .string("s1"),
            "item_id": .string("i1"),
            "delta": .string("1")
        ]))

        #expect(viewModel.selectedMessages.map(\.text) == ["A1", "B"])
    }

    @Test func approvalRequestCreatesPendingRequestAndAcceptResponds() async {
        let repository = MockChatRepository()
        let viewModel = ChatViewModel(repository: repository)
        seedSession("s1", in: viewModel)

        viewModel.apply(frame: .serverRequest(id: "srv-1", method: "approval/request", params: [
            "request_id": .string("srv-1"),
            "thread_id": .string("s1"),
            "turn_id": .string("t1"),
            "scope": .string("turn"),
            "prompt": .string("Allow command execution?")
        ]))

        #expect(viewModel.pendingServerRequests.count == 1)
        #expect(viewModel.pendingServerRequests.first?.prompt == "Allow command execution?")

        viewModel.respondToServerRequest(viewModel.pendingServerRequests[0], decision: "accept")
        await Task.yield()

        #expect(repository.approvalResponses == [
            ApprovalResponse(requestID: "srv-1", threadID: "s1", turnID: "t1", decision: "accept")
        ])
    }

    @Test func createSessionResultClearsPendingState() {
        let viewModel = ChatViewModel(repository: MockChatRepository())
        viewModel.apply(frame: .result(id: "bootstrap", result: ["sessions": .array([])]))

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

    @Test func sendDraftAfterSelectingSessionClearsInputAndSubmitsTurn() async {
        let repository = MockChatRepository()
        let viewModel = ChatViewModel(repository: repository)
        seedSession("s1", in: viewModel)
        viewModel.draft = "hello"

        viewModel.sendDraft()
        await Task.yield()

        #expect(viewModel.draft.isEmpty)
        #expect(repository.submittedTurns == [
            SubmittedTurn(sessionKey: "s1", input: "hello", stream: true)
        ])
        #expect(viewModel.selectedMessages.first?.role == .user)
        #expect(viewModel.selectedMessages.first?.text == "hello")
    }

    @Test func repositoryBuildsV1TurnStartParams() async throws {
        let client = MockWebSocketClient()
        let repository = ChatRepository(client: client, settingsStore: MockSettingsStore())

        try await repository.submit(
            sessionKey: "s1",
            input: "hello",
            stream: true,
            route: ModelRoute(provider: "anthropic", model: "claude-sonnet-4-5"),
            attachments: [
                ArchiveAttachment(archiveID: "archive-1", filename: "report.pdf", mimeType: "application/pdf", sizeBytes: 100)
            ]
        )

        #expect(client.sentMethods == ["turn/start"])
        #expect(client.sentParams.first?["session_id"] == .string("s1"))
        #expect(client.sentParams.first?["thread_id"] == .string("s1"))
        #expect(client.sentParams.first?["stream"] == .bool(true))
        #expect(client.sentParams.first?["model_provider"] == .string("anthropic"))
        #expect(client.sentParams.first?["model"] == .string("claude-sonnet-4-5"))
        #expect(client.sentParams.first?.array("input") == [
            .object(["type": .string("text"), "text": .string("hello")]),
            .object([
                "type": .string("attachment"),
                "archive_id": .string("archive-1"),
                "filename": .string("report.pdf"),
                "mime_type": .string("application/pdf"),
                "size_bytes": .number(100)
            ])
        ])
    }

    @Test func repositoryBuildsV1ControlAndServerRequestResponses() async throws {
        let client = MockWebSocketClient()
        let repository = ChatRepository(client: client, settingsStore: MockSettingsStore())

        try await repository.cancelTurn(sessionKey: "s1", threadID: "s1", turnID: "t1")
        try await repository.respondToApproval(requestID: "srv-1", threadID: "s1", turnID: "t1", decision: "reject")
        try await repository.respondToTool(requestID: "srv-2", threadID: "s1", turnID: "t1", result: ["ok": .bool(true)])
        try await repository.respondToUserInput(requestID: "srv-3", threadID: "s1", turnID: "t1", input: "more context")

        #expect(client.sentMethods == ["turn/cancel", "approval/respond", "tool/respond", "user_input/respond"])
        #expect(client.sentParams[0]["turn_id"] == .string("t1"))
        #expect(client.sentParams[1]["decision"] == .string("reject"))
        #expect(client.sentParams[2]["result"] == .object(["ok": .bool(true)]))
        #expect(client.sentParams[3]["input"] == .string("more context"))
    }

    private func seedSession(_ sessionKey: String, in viewModel: ChatViewModel) {
        viewModel.apply(frame: .result(id: "bootstrap", result: [
            "sessions": .array([
                .object([
                    "session_key": .string(sessionKey),
                    "title": .string("Agent"),
                    "created_at_ms": .number(1)
                ])
            ])
        ]))
        if let session = viewModel.sessions.first(where: { $0.sessionKey == sessionKey }) {
            viewModel.selectSession(session)
        }
    }
}

private final class MockChatRepository: ChatRepositoryProtocol {
    var frames: AsyncStream<ServerFrame> { AsyncStream { _ in } }
    var settings = GatewaySettings.defaults
    var initializeRequestCount = 0
    var bootstrapRequestCount = 0
    var providerListRequestCount = 0
    var createdSessionRequestCount = 0
    var approvalResponses: [ApprovalResponse] = []
    var cancelledTurns: [TurnReference] = []
    var submittedTurns: [SubmittedTurn] = []

    func save(settings: GatewaySettings) {
        self.settings = settings
    }

    func connect(settings: GatewaySettings) async throws {}
    func disconnect() {}
    func initialize() async throws {
        initializeRequestCount += 1
    }
    func bootstrap() async throws -> [String: JSONValue] {
        bootstrapRequestCount += 1
        return ["sessions": .array([])]
    }
    func listProviders() async throws -> [String: JSONValue] {
        providerListRequestCount += 1
        return ["providers": .array([])]
    }
    func createSession() async throws {
        createdSessionRequestCount += 1
    }
    func updateSession(sessionKey: String, title: String, modelProvider: String?, model: String?) async throws {}
    func deleteSession(sessionKey: String) async throws {}
    func subscribe(sessionKey: String) async throws {}
    func loadHistory(sessionKey: String, beforeMessageID: String?, limit: Int) async throws {}
    func submit(sessionKey: String, input: String, stream: Bool, route: ModelRoute, attachments: [ArchiveAttachment]) async throws {
        submittedTurns.append(SubmittedTurn(sessionKey: sessionKey, input: input, stream: stream))
    }
    func cancelTurn(sessionKey: String, threadID: String, turnID: String) async throws {
        cancelledTurns.append(TurnReference(sessionID: sessionKey, threadID: threadID, turnID: turnID))
    }
    func respondToApproval(requestID: String, threadID: String, turnID: String, decision: String) async throws {
        approvalResponses.append(ApprovalResponse(requestID: requestID, threadID: threadID, turnID: turnID, decision: decision))
    }
    func respondToTool(requestID: String, threadID: String, turnID: String, result: [String: JSONValue]) async throws {}
    func respondToUserInput(requestID: String, threadID: String, turnID: String, input: String) async throws {}
}

private struct SubmittedTurn: Equatable {
    var sessionKey: String
    var input: String
    var stream: Bool
}

private final class MockWebSocketClient: GatewayWebSocketClientProtocol {
    var frames: AsyncStream<ServerFrame> { AsyncStream { _ in } }
    var sentMethods: [String] = []
    var sentNotifications: [String] = []
    var sentParams: [[String: JSONValue]] = []

    func connect(baseURLString: String, token: String?) async throws {}
    func disconnect() {}

    func send(method: String, params: [String: JSONValue]) async throws -> String {
        sentMethods.append(method)
        sentParams.append(params)
        return "request-id"
    }

    func sendNotification(method: String, params: [String: JSONValue]) async throws {
        sentNotifications.append(method)
        sentParams.append(params)
    }

    func sendAndWaitResult(
        method: String,
        params: [String: JSONValue],
        timeoutNanoseconds: UInt64
    ) async throws -> [String: JSONValue] {
        sentMethods.append(method)
        sentParams.append(params)
        return ["protocol_version": .string("v1")]
    }
}

private struct MockSettingsStore: GatewaySettingsStore {
    func load() -> GatewaySettings {
        .defaults
    }

    func save(_ settings: GatewaySettings) {}
}
