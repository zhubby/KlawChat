import Combine
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var settings: GatewaySettings
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var sessions: [WorkspaceSession] = []
    @Published private(set) var messagesBySession: [String: [ChatMessage]] = [:]
    @Published private(set) var providerCatalog: ProviderCatalog = .empty
    @Published var selectedSessionKey: String?
    @Published var draft: String = ""
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var isLoadingHistory = false
    @Published private(set) var isWorkspaceLoaded = false
    @Published private(set) var isCreatingSession = false
    @Published private(set) var pendingServerRequests: [PendingServerRequest] = []

    private let repository: ChatRepositoryProtocol
    private var frameTask: Task<Void, Never>?
    private var subscribedSessionKeys: Set<String> = []
    private var oldestLoadedMessageIDs: [String: String] = [:]
    private var historyHasMore: [String: Bool] = [:]
    private var createSessionRequestID: UUID?
    private var activeTurnsBySession: [String: TurnReference] = [:]
    private var messageIDsByItemID: [String: String] = [:]

    init(repository: ChatRepositoryProtocol) {
        self.repository = repository
        self.settings = repository.settings
        self.selectedSessionKey = nil
    }

    var selectedSession: WorkspaceSession? {
        sessions.first { $0.sessionKey == selectedSessionKey }
    }

    var selectedMessages: [ChatMessage] {
        guard let selectedSessionKey else { return [] }
        return messagesBySession[selectedSessionKey, default: []]
    }

    var selectedRoute: ModelRoute {
        providerCatalog.resolvedRoute(
            provider: selectedSession?.modelProvider,
            model: selectedSession?.model
        )
    }

    var canSend: Bool {
        connectionState == .connected
            && selectedSessionKey != nil
            && draft.nilIfBlank != nil
    }

    var canCreateSession: Bool {
        connectionState == .connected
            && isWorkspaceLoaded
            && !isCreatingSession
    }

    var activeTurnForSelectedSession: TurnReference? {
        guard let selectedSessionKey else { return nil }
        return activeTurnsBySession[selectedSessionKey]
    }

    var pendingServerRequestsForSelectedSession: [PendingServerRequest] {
        guard let selectedSessionKey else { return pendingServerRequests }
        return pendingServerRequests.filter { request in
            request.threadID == selectedSessionKey
                || request.params.string("session_id") == selectedSessionKey
                || request.params.string("session_key") == selectedSessionKey
        }
    }

    func connect() {
        connectionState = .connecting
        errorMessage = nil
        isWorkspaceLoaded = false
        selectedSessionKey = nil
        settings.lastSessionKey = nil
        saveSettings()
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            await self?.consumeFrames()
        }

        Task {
            do {
                try await repository.connect(settings: settings)
                try await repository.initialize()
                connectionState = .connected
                let sessionsResult = try await repository.bootstrap()
                apply(result: sessionsResult, id: "session/list")
                let providersResult = try await repository.listProviders()
                apply(result: providersResult, id: "provider/list")
            } catch {
                show(error)
            }
        }
    }

    func disconnect() {
        repository.disconnect()
        connectionState = .disconnected
        isWorkspaceLoaded = false
        isCreatingSession = false
        createSessionRequestID = nil
        activeTurnsBySession.removeAll()
        messageIDsByItemID.removeAll()
        pendingServerRequests.removeAll()
        subscribedSessionKeys.removeAll()
    }

    func saveSettings() {
        repository.save(settings: settings)
    }

    func refreshSessions() async {
        guard connectionState == .connected else {
            return
        }

        do {
            errorMessage = nil
            let sessionsResult = try await repository.bootstrap()
            apply(result: sessionsResult, id: "session/list")
        } catch {
            show(error)
        }
    }

    func createSession() {
        guard canCreateSession else {
            if connectionState != .connected {
                showMessage("Connect to the gateway before creating an agent.")
            } else if !isWorkspaceLoaded {
                statusMessage = "Workspace is still loading."
            }
            return
        }
        isCreatingSession = true
        statusMessage = "Creating agent..."
        errorMessage = nil
        let requestID = UUID()
        createSessionRequestID = requestID
        Task {
            do {
                try await repository.createSession()
                try await Task.sleep(nanoseconds: 10_000_000_000)
                if isCreatingSession && createSessionRequestID == requestID {
                    isCreatingSession = false
                    createSessionRequestID = nil
                    statusMessage = nil
                    showMessage("Create agent timed out. Check the gateway connection and try again.")
                }
            } catch {
                if isCreatingSession && createSessionRequestID == requestID {
                    isCreatingSession = false
                    createSessionRequestID = nil
                    statusMessage = nil
                    show(error)
                }
            }
        }
    }

    func updateSelectedSession(title: String, modelProvider: String?, model: String?) {
        guard let selectedSessionKey, let title = title.nilIfBlank else { return }
        Task {
            do {
                try await repository.updateSession(
                    sessionKey: selectedSessionKey,
                    title: title,
                    modelProvider: modelProvider,
                    model: model
                )
            } catch {
                show(error)
            }
        }
    }

    func deleteSession(_ session: WorkspaceSession) {
        Task {
            do {
                try await repository.deleteSession(sessionKey: session.sessionKey)
            } catch {
                show(error)
            }
        }
    }

    func selectSession(_ session: WorkspaceSession) {
        selectedSessionKey = session.sessionKey
        settings.lastSessionKey = session.sessionKey
        saveSettings()
        ensureSessionReady(session.sessionKey)
    }

    func ensureSelectedSessionReady() {
        guard let selectedSessionKey else { return }
        ensureSessionReady(selectedSessionKey)
    }

    func loadOlderHistory() {
        guard let selectedSessionKey,
              historyHasMore[selectedSessionKey, default: true],
              !isLoadingHistory else {
            return
        }
        loadHistory(sessionKey: selectedSessionKey, beforeMessageID: oldestLoadedMessageIDs[selectedSessionKey])
    }

    func sendDraft() {
        guard let selectedSessionKey, let text = draft.nilIfBlank else { return }
        let route = selectedRoute
        draft = ""
        appendMessage(
            ChatMessage(role: .user, text: text),
            sessionKey: selectedSessionKey
        )
        if settings.streamEnabled {
            appendMessage(
                ChatMessage(role: .assistant, text: "", isStreaming: true),
                sessionKey: selectedSessionKey
            )
        }

        Task {
            do {
                try await repository.submit(
                    sessionKey: selectedSessionKey,
                    input: text,
                    stream: settings.streamEnabled,
                    route: route,
                    attachments: []
                )
                await reconcileSubmittedTurnFromHistory(sessionKey: selectedSessionKey)
            } catch {
                draft = text
                removeEmptyStreamingMessage(sessionKey: selectedSessionKey)
                show(error)
            }
        }
    }

    func cancelCurrentTurn() {
        guard let turn = activeTurnForSelectedSession else { return }
        Task {
            do {
                try await repository.cancelTurn(
                    sessionKey: turn.sessionID,
                    threadID: turn.threadID,
                    turnID: turn.turnID
                )
            } catch {
                show(error)
            }
        }
    }

    func respondToServerRequest(_ request: PendingServerRequest, decision: String) {
        Task {
            do {
                switch request.method {
                case "approval/request":
                    try await repository.respondToApproval(
                        requestID: request.requestID,
                        threadID: request.threadID,
                        turnID: request.turnID,
                        decision: decision
                    )
                case "tool/request":
                    try await repository.respondToTool(
                        requestID: request.requestID,
                        threadID: request.threadID,
                        turnID: request.turnID,
                        result: ["decision": .string(decision)]
                    )
                case "tool/requestUserInput", "user_input/request":
                    try await repository.respondToUserInput(
                        requestID: request.requestID,
                        threadID: request.threadID,
                        turnID: request.turnID,
                        input: decision
                    )
                    try await refreshLatestHistory(sessionKey: request.threadID)
                default:
                    break
                }
                removePendingServerRequest(request.requestID)
            } catch {
                show(error)
            }
        }
    }

    func apply(frame: ServerFrame) {
        switch frame {
        case .result(let id, let result):
            apply(result: result, id: id)
        case .notification(let method, let params):
            apply(notification: method, params: params)
        case .serverRequest(let id, let method, let params):
            apply(serverRequestID: id, method: method, params: params)
        case .error(_, let error):
            isCreatingSession = false
            createSessionRequestID = nil
            statusMessage = nil
            showMessage("\(error.code): \(error.message)")
        }
    }

    private func consumeFrames() async {
        for await frame in repository.frames {
            if Task.isCancelled { return }
            apply(frame: frame)
        }
    }

    private func ensureSessionReady(_ sessionKey: String) {
        if !subscribedSessionKeys.contains(sessionKey) {
            subscribedSessionKeys.insert(sessionKey)
            Task {
                do {
                    try await repository.subscribe(sessionKey: sessionKey)
                } catch {
                    show(error)
                }
            }
        }

        if messagesBySession[sessionKey, default: []].isEmpty {
            loadHistory(sessionKey: sessionKey, beforeMessageID: nil)
        }
    }

    private func loadHistory(sessionKey: String, beforeMessageID: String?) {
        isLoadingHistory = true
        Task {
            do {
                let result = try await repository.loadHistory(
                    sessionKey: sessionKey,
                    beforeMessageID: beforeMessageID,
                    limit: 30
                )
                apply(result: result, id: "thread/history")
            } catch {
                isLoadingHistory = false
                show(error)
            }
        }
    }

    private func refreshLatestHistory(sessionKey: String) async throws {
        let result = try await repository.loadHistory(
            sessionKey: sessionKey,
            beforeMessageID: nil,
            limit: 30
        )
        mergeLatestHistory(result, sessionKey: result.string("session_key") ?? sessionKey)
    }

    private func reconcileSubmittedTurnFromHistory(sessionKey: String) async {
        let retryDelays: [UInt64] = [
            0,
            1_000_000_000,
            2_000_000_000,
            3_000_000_000,
            5_000_000_000
        ]

        for delay in retryDelays {
            if Task.isCancelled || !hasPendingStreamingAssistant(sessionKey: sessionKey) {
                return
            }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            do {
                try await refreshLatestHistory(sessionKey: sessionKey)
            } catch {
                return
            }
        }
    }

    private func apply(result: [String: JSONValue], id: String) {
        if let turn = result.object("turn") {
            rememberActiveTurn(turn)
            return
        }

        if let sessionValues = result.array("sessions") {
            let parsedSessions = sessionValues.compactMap { $0.objectValue?.workspaceSession }
            sessions = parsedSessions.sorted { $0.createdAtMilliseconds > $1.createdAtMilliseconds }
            isWorkspaceLoaded = true
            clearSelectionIfMissing()
            return
        }

        if let providerValues = result.array("providers") {
            providerCatalog = ProviderCatalog(
                defaultProvider: result.string("default_provider"),
                providers: providerValues.compactMap { $0.objectValue?.provider }
            )
            return
        }

        if let messages = result.array("messages"),
           let sessionKey = result.string("session_key") {
            prependHistory(messages, sessionKey: sessionKey, result: result)
            return
        }

        if result.bool("updated") == true,
           let sessionKey = result.string("session_key"),
           let title = result.string("title") {
            updateSession(sessionKey: sessionKey, title: title, result: result)
            return
        }

        if result.bool("deleted") == true,
           let sessionKey = result.string("session_key") {
            removeSession(sessionKey)
            return
        }

        if let sessionKey = result.string("session_key"),
           let title = result.string("title"),
           let createdAtMilliseconds = result.int("created_at_ms") {
            isCreatingSession = false
            createSessionRequestID = nil
            statusMessage = "Created \(title)"
            upsertSession(WorkspaceSession(
                sessionKey: sessionKey,
                title: title,
                createdAtMilliseconds: createdAtMilliseconds,
                modelProvider: result.string("model_provider"),
                model: result.string("model")
            ))
            selectedSessionKey = sessionKey
            settings.lastSessionKey = sessionKey
            saveSettings()
            ensureSessionReady(sessionKey)
            return
        }

    }

    private func apply(notification method: String, params: [String: JSONValue]) {
        switch method {
        case "session/subscribed":
            if let sessionKey = params.string("session_key") {
                subscribedSessionKeys.insert(sessionKey)
            }
        case "session/unsubscribed":
            if let sessionKey = params.string("session_key") {
                subscribedSessionKeys.remove(sessionKey)
            }
        case "turn/started":
            rememberActiveTurn(params)
        case "item/started":
            applyItem(params.object("item"), sessionKey: params.sessionIdentifier, isCompleted: false)
        case "item/agentMessage/delta":
            guard let sessionKey = params.sessionIdentifier else { return }
            appendStreamDelta(params.string("delta") ?? "", sessionKey: sessionKey, itemID: params.string("item_id"))
        case "item/completed":
            applyItem(params.object("item"), sessionKey: params.sessionIdentifier, isCompleted: true)
        case "turn/completed":
            if let sessionKey = params.sessionIdentifier {
                if let response = params.object("response"),
                   let content = response.string("content"),
                   !content.isEmpty {
                    replaceStreamingMessage(
                        with: content,
                        sessionKey: sessionKey,
                        messageID: response.string("message_id"),
                        metadata: response.object("metadata") ?? [:]
                    )
                }
                markStreamingDone(sessionKey: sessionKey)
                activeTurnsBySession[sessionKey] = nil
            }
        case "turn/failed":
            if let sessionKey = params.sessionIdentifier {
                removeEmptyStreamingMessage(sessionKey: sessionKey)
                activeTurnsBySession[sessionKey] = nil
                appendSystemMessage(params.string("error") ?? params.string("message") ?? "Turn failed.", sessionKey: sessionKey)
            }
        case "turn/interrupted":
            if let sessionKey = params.sessionIdentifier {
                removeEmptyStreamingMessage(sessionKey: sessionKey)
                activeTurnsBySession[sessionKey] = nil
                markStreamingDone(sessionKey: sessionKey)
            }
        case "serverRequest/resolved":
            if let requestID = params.string("request_id") {
                removePendingServerRequest(requestID)
            }
        default:
            break
        }
    }

    private func apply(serverRequestID id: String, method: String, params: [String: JSONValue]) {
        let requestID = params.string("request_id") ?? id
        let threadID = params.string("thread_id") ?? params.string("session_id") ?? selectedSessionKey ?? ""
        let turnID = params.string("turn_id") ?? ""
        let prompt = params.string("prompt")
            ?? params.string("message")
            ?? "\(method) requires a response."
        let request = PendingServerRequest(
            requestID: requestID,
            method: method,
            threadID: threadID,
            turnID: turnID,
            prompt: prompt,
            scope: params.string("scope"),
            params: params
        )
        if !pendingServerRequests.contains(where: { $0.requestID == requestID }) {
            pendingServerRequests.append(request)
        }
        appendSystemMessage("\(request.kindLabel): \(prompt)", sessionKey: threadID)
    }

    private func applyItem(_ item: [String: JSONValue]?, sessionKey explicitSessionKey: String?, isCompleted: Bool) {
        guard let item else {
            return
        }
        let sessionKey = explicitSessionKey ?? item.string("session_id") ?? selectedSessionKey
        guard let sessionKey else { return }
        let itemID = item.string("item_id")
        let type = item.string("type") ?? "unknown"

        switch type {
        case "agentMessage":
            guard let response = item.object("payload")?.object("response") else { return }
            let content = response.string("content") ?? ""
            guard !content.isEmpty else { return }
            replaceStreamingMessage(
                with: content,
                sessionKey: sessionKey,
                messageID: itemID,
                metadata: response.object("metadata") ?? [:]
            )
        case "userMessage":
            guard isCompleted,
                  let content = item.object("payload")?.object("message")?.string("content"),
                  !messageExists(itemID, sessionKey: sessionKey) else {
                return
            }
            appendMessage(ChatMessage(role: .user, text: content, messageID: itemID), sessionKey: sessionKey)
        default:
            if isCompleted {
                appendSystemMessage("\(type) completed.", sessionKey: sessionKey)
            }
        }
    }

    private func prependHistory(
        _ values: [JSONValue],
        sessionKey: String,
        result: [String: JSONValue]
    ) {
        let current = messagesBySession[sessionKey, default: []]
        let existingIDs = Set(current.compactMap(\.messageID))
        let history = values.compactMap { value -> ChatMessage? in
            guard let object = value.objectValue,
                  let role = MessageRole(rawValue: object.string("role") ?? "assistant"),
                  let content = object.string("content") else {
                return nil
            }
            let messageID = object.string("message_id")
            if let messageID, existingIDs.contains(messageID) {
                return nil
            }
            return ChatMessage(
                role: role,
                text: content,
                timestampMilliseconds: object.int("timestamp_ms") ?? nowMilliseconds(),
                messageID: messageID,
                metadata: object.object("metadata") ?? [:]
            )
        }
        messagesBySession[sessionKey] = history + current
        isLoadingHistory = false
        historyHasMore[sessionKey] = result.bool("has_more") ?? false
        oldestLoadedMessageIDs[sessionKey] = result.string("oldest_loaded_message_id")
    }

    private func mergeLatestHistory(_ result: [String: JSONValue], sessionKey: String) {
        guard let values = result.array("messages") else { return }
        let serverMessages = parsedHistoryMessages(values)
        guard !serverMessages.isEmpty else { return }

        var current = messagesBySession[sessionKey, default: []]
        var consumedLocalIDs = Set<String>()
        var didMergeAssistantResponse = false

        for serverMessage in serverMessages {
            if let messageID = serverMessage.messageID,
               let index = current.firstIndex(where: { $0.messageID == messageID }) {
                current[index] = serverMessage
                consumedLocalIDs.insert(current[index].id)
                didMergeAssistantResponse = didMergeAssistantResponse || serverMessage.role == .assistant
                continue
            }

            if let index = current.firstIndex(where: {
                !consumedLocalIDs.contains($0.id)
                    && $0.messageID == nil
                    && $0.role == serverMessage.role
                    && $0.text == serverMessage.text
            }) {
                current[index].messageID = serverMessage.messageID
                current[index].timestampMilliseconds = serverMessage.timestampMilliseconds
                current[index].metadata = serverMessage.metadata
                current[index].isStreaming = false
                consumedLocalIDs.insert(current[index].id)
                didMergeAssistantResponse = didMergeAssistantResponse || serverMessage.role == .assistant
                continue
            }

            if serverMessage.role == .assistant,
               let index = current.firstIndex(where: {
                   !consumedLocalIDs.contains($0.id)
                       && $0.role == .assistant
                       && $0.isStreaming
               }) {
                current[index].text = serverMessage.text
                current[index].messageID = serverMessage.messageID
                current[index].timestampMilliseconds = serverMessage.timestampMilliseconds
                current[index].metadata = serverMessage.metadata
                current[index].isStreaming = false
                consumedLocalIDs.insert(current[index].id)
                didMergeAssistantResponse = true
                continue
            }

            current.append(serverMessage)
            didMergeAssistantResponse = didMergeAssistantResponse || serverMessage.role == .assistant
        }

        if didMergeAssistantResponse {
            current.removeAll { $0.role == .assistant && $0.isStreaming && $0.text.isEmpty }
        }

        messagesBySession[sessionKey] = current
        isLoadingHistory = false
        historyHasMore[sessionKey] = result.bool("has_more") ?? historyHasMore[sessionKey, default: false]
        oldestLoadedMessageIDs[sessionKey] = result.string("oldest_loaded_message_id") ?? oldestLoadedMessageIDs[sessionKey]
    }

    private func parsedHistoryMessages(_ values: [JSONValue]) -> [ChatMessage] {
        values.compactMap { value -> ChatMessage? in
            guard let object = value.objectValue,
                  let role = MessageRole(rawValue: object.string("role") ?? "assistant"),
                  let content = object.string("content") else {
                return nil
            }
            return ChatMessage(
                role: role,
                text: content,
                timestampMilliseconds: object.int("timestamp_ms") ?? nowMilliseconds(),
                messageID: object.string("message_id"),
                metadata: object.object("metadata") ?? [:]
            )
        }
    }

    private func appendStreamDelta(_ delta: String, sessionKey: String, itemID: String?) {
        guard !delta.isEmpty else { return }
        var messages = messagesBySession[sessionKey, default: []]
        if let itemID,
           let localMessageID = messageIDsByItemID[itemID],
           let index = messages.firstIndex(where: { $0.id == localMessageID }) {
            messages[index].text += delta
        } else if let index = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming && $0.text.isEmpty && $0.messageID == nil }) {
            messages[index].text += delta
            messages[index].messageID = itemID
            if let itemID {
                messageIDsByItemID[itemID] = messages[index].id
            }
        } else {
            let message = ChatMessage(role: .assistant, text: delta, messageID: itemID, isStreaming: true)
            messages.append(message)
            if let itemID {
                messageIDsByItemID[itemID] = message.id
            }
        }
        messagesBySession[sessionKey] = messages
    }

    private func replaceStreamingMessage(
        with content: String,
        sessionKey: String,
        messageID: String?,
        metadata: [String: JSONValue] = [:]
    ) {
        var messages = messagesBySession[sessionKey, default: []]
        if let messageID,
           let localMessageID = messageIDsByItemID[messageID],
           let index = messages.firstIndex(where: { $0.id == localMessageID }) {
            messages[index].text = content
            messages[index].messageID = messageID
            messages[index].metadata = metadata
            messages[index].isStreaming = false
        } else if let index = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            messages[index].text = content
            messages[index].messageID = messageID
            messages[index].metadata = metadata
            messages[index].isStreaming = false
            if let messageID {
                messageIDsByItemID[messageID] = messages[index].id
            }
        } else {
            let message = ChatMessage(role: .assistant, text: content, messageID: messageID, metadata: metadata)
            messages.append(message)
            if let messageID {
                messageIDsByItemID[messageID] = message.id
            }
        }
        messagesBySession[sessionKey] = messages
    }

    private func markStreamingDone(sessionKey: String) {
        var messages = messagesBySession[sessionKey, default: []]
        if let index = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            messages[index].isStreaming = false
        }
        messagesBySession[sessionKey] = messages
    }

    private func removeEmptyStreamingMessage(sessionKey: String) {
        messagesBySession[sessionKey, default: []].removeAll {
            $0.role == .assistant && $0.isStreaming && $0.text.isEmpty
        }
    }

    private func hasPendingStreamingAssistant(sessionKey: String) -> Bool {
        messagesBySession[sessionKey, default: []].contains {
            $0.role == .assistant && $0.isStreaming
        }
    }

    private func appendMessage(_ message: ChatMessage, sessionKey: String) {
        messagesBySession[sessionKey, default: []].append(message)
    }

    private func appendSystemMessage(_ text: String, sessionKey: String) {
        guard !text.isEmpty else { return }
        appendMessage(ChatMessage(role: .system, text: text), sessionKey: sessionKey)
    }

    private func messageExists(_ messageID: String?, sessionKey: String) -> Bool {
        guard let messageID else { return false }
        return messagesBySession[sessionKey, default: []].contains { $0.messageID == messageID }
    }

    private func clearSelectionIfMissing() {
        guard let selectedSessionKey,
              sessions.contains(where: { $0.sessionKey == selectedSessionKey }) else {
            self.selectedSessionKey = nil
            settings.lastSessionKey = nil
            saveSettings()
            return
        }
    }

    private func upsertSession(_ session: WorkspaceSession) {
        if let index = sessions.firstIndex(where: { $0.sessionKey == session.sessionKey }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.createdAtMilliseconds > $1.createdAtMilliseconds }
    }

    private func updateSession(sessionKey: String, title: String, result: [String: JSONValue]) {
        guard let index = sessions.firstIndex(where: { $0.sessionKey == sessionKey }) else { return }
        sessions[index].title = title
        sessions[index].modelProvider = result.string("model_provider")
        sessions[index].model = result.string("model")
    }

    private func removeSession(_ sessionKey: String) {
        sessions.removeAll { $0.sessionKey == sessionKey }
        messagesBySession[sessionKey] = nil
        let remainingMessageIDs = Set(messagesBySession.values.flatMap { $0.map(\.id) })
        messageIDsByItemID = messageIDsByItemID.filter { remainingMessageIDs.contains($0.value) }
        subscribedSessionKeys.remove(sessionKey)
        if selectedSessionKey == sessionKey {
            selectedSessionKey = sessions.first?.sessionKey
        }
    }

    private func show(_ error: Error) {
        showMessage(error.localizedDescription)
    }

    private func showMessage(_ message: String) {
        errorMessage = message
        connectionState = .error(message)
    }

    private func rememberActiveTurn(_ params: [String: JSONValue]) {
        guard let sessionID = params.sessionIdentifier,
              let threadID = params.string("thread_id") ?? params.sessionIdentifier,
              let turnID = params.string("turn_id") else {
            return
        }
        activeTurnsBySession[sessionID] = TurnReference(sessionID: sessionID, threadID: threadID, turnID: turnID)
    }

    private func removePendingServerRequest(_ requestID: String) {
        pendingServerRequests.removeAll { $0.requestID == requestID }
    }

    private func nowMilliseconds() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    var sessionIdentifier: String? {
        string("session_id") ?? string("session_key")
    }

    var workspaceSession: WorkspaceSession? {
        guard let sessionKey = string("session_key"),
              let title = string("title"),
              let createdAtMilliseconds = int("created_at_ms") else {
            return nil
        }
        return WorkspaceSession(
            sessionKey: sessionKey,
            title: title,
            createdAtMilliseconds: createdAtMilliseconds,
            modelProvider: string("model_provider"),
            model: string("model")
        )
    }

    var provider: Provider? {
        guard let id = string("id"),
              let defaultModel = string("default_model") else {
            return nil
        }
        return Provider(
            id: id,
            name: string("name"),
            defaultModel: defaultModel,
            stream: bool("stream"),
            hasAPIKey: bool("has_api_key")
        )
    }
}
