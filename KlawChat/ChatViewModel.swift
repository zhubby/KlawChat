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

    private let repository: ChatRepositoryProtocol
    private var frameTask: Task<Void, Never>?
    private var subscribedSessionKeys: Set<String> = []
    private var oldestLoadedMessageIDs: [String: String] = [:]
    private var historyHasMore: [String: Bool] = [:]
    private var bootstrapRequestID: String?
    private var createSessionRequestID: UUID?
    private var activeStreamRequestIDs: [String: String] = [:]

    init(repository: ChatRepositoryProtocol) {
        self.repository = repository
        self.settings = repository.settings
        self.selectedSessionKey = repository.settings.lastSessionKey
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

    func connect() {
        connectionState = .connecting
        errorMessage = nil
        isWorkspaceLoaded = false
        bootstrapRequestID = nil
        saveSettings()
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            await self?.consumeFrames()
        }

        Task {
            do {
                try await repository.connect(settings: settings)
                connectionState = .connected
                bootstrapRequestID = try await repository.bootstrap()
                try await repository.listProviders()
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
        bootstrapRequestID = nil
        createSessionRequestID = nil
        activeStreamRequestIDs.removeAll()
        subscribedSessionKeys.removeAll()
    }

    func saveSettings() {
        repository.save(settings: settings)
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
            } catch {
                draft = text
                removeEmptyStreamingMessage(sessionKey: selectedSessionKey)
                show(error)
            }
        }
    }

    func apply(frame: ServerFrame) {
        switch frame {
        case .result(let id, let result):
            apply(result: result, id: id)
        case .event(let event, let payload):
            apply(event: event, payload: payload)
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
                try await repository.loadHistory(
                    sessionKey: sessionKey,
                    beforeMessageID: beforeMessageID,
                    limit: 30
                )
            } catch {
                isLoadingHistory = false
                show(error)
            }
        }
    }

    private func apply(result: [String: JSONValue], id: String) {
        if let sessionValues = result.array("sessions") {
            let parsedSessions = sessionValues.compactMap { $0.objectValue?.workspaceSession }
            sessions = parsedSessions.sorted { $0.createdAtMilliseconds > $1.createdAtMilliseconds }
            isWorkspaceLoaded = true
            if id == bootstrapRequestID {
                bootstrapRequestID = nil
            }
            selectInitialSession(activeSessionKey: result.string("active_session_key"))
            return
        }

        if id == bootstrapRequestID {
            isWorkspaceLoaded = true
            bootstrapRequestID = nil
            return
        }

        if let providerValues = result.array("providers") {
            providerCatalog = ProviderCatalog(
                defaultProvider: result.string("default_provider"),
                providers: providerValues.compactMap { $0.objectValue?.provider }
            )
            if bootstrapRequestID != nil {
                isWorkspaceLoaded = true
                bootstrapRequestID = nil
            }
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

        if let sessionKey = result.string("session_key"),
           let response = result.object("response"),
           let content = response.string("content"),
           !content.isEmpty {
            appendAssistantResponse(content, sessionKey: sessionKey, result: result, response: response)
        }
    }

    private func apply(event: String, payload: [String: JSONValue]) {
        switch event {
        case "session.connected":
            connectionState = .connected
        case "session.subscribed":
            if let sessionKey = payload.string("session_key") {
                subscribedSessionKeys.insert(sessionKey)
            }
        case "session.message":
            applySessionMessage(payload)
        case "session.stream.delta":
            guard let sessionKey = payload.string("session_key") else { return }
            appendStreamDelta(payload.string("delta") ?? "", sessionKey: sessionKey)
        case "session.stream.clear":
            if let sessionKey = payload.string("session_key") {
                removeEmptyStreamingMessage(sessionKey: sessionKey)
            }
        case "session.stream.done":
            guard let sessionKey = payload.string("session_key") else { return }
            if let response = payload.object("response"),
               let content = response.string("content"),
               !content.isEmpty {
                replaceStreamingMessage(with: content, sessionKey: sessionKey, messageID: payload.string("message_id"))
            } else {
                markStreamingDone(sessionKey: sessionKey)
            }
        default:
            break
        }
    }

    private func applySessionMessage(_ payload: [String: JSONValue]) {
        guard let sessionKey = payload.string("session_key"),
              let response = payload.object("response") else {
            return
        }
        let content = response.string("content") ?? ""
        let role = MessageRole(rawValue: payload.string("role") ?? "") ?? .assistant
        let messageID = payload.string("message_id")
        guard !messageExists(messageID, sessionKey: sessionKey) else { return }
        if role == .assistant, content.isEmpty { return }
        let requestID = payload.string("request_id")
        let historyEvent = payload.bool("history") ?? false

        if role == .assistant && !historyEvent {
            mergeAssistantStreamMessage(
                content: content,
                sessionKey: sessionKey,
                requestID: requestID,
                messageID: messageID,
                timestampMilliseconds: payload.int("timestamp_ms") ?? nowMilliseconds(),
                metadata: response.object("metadata") ?? [:]
            )
            return
        }

        appendMessage(
            ChatMessage(
                role: role,
                text: content,
                timestampMilliseconds: payload.int("timestamp_ms") ?? nowMilliseconds(),
                messageID: messageID,
                metadata: response.object("metadata") ?? [:]
            ),
            sessionKey: sessionKey
        )
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

    private func appendAssistantResponse(
        _ content: String,
        sessionKey: String,
        result: [String: JSONValue],
        response: [String: JSONValue]
    ) {
        if messageExists(result.string("message_id"), sessionKey: sessionKey) {
            return
        }
        replaceStreamingMessage(
            with: content,
            sessionKey: sessionKey,
            messageID: result.string("message_id"),
            metadata: response.object("metadata") ?? [:]
        )
    }

    private func appendStreamDelta(_ delta: String, sessionKey: String) {
        guard !delta.isEmpty else { return }
        var messages = messagesBySession[sessionKey, default: []]
        if let index = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            messages[index].text += delta
        } else {
            messages.append(ChatMessage(role: .assistant, text: delta, isStreaming: true))
        }
        messagesBySession[sessionKey] = messages
    }

    private func mergeAssistantStreamMessage(
        content: String,
        sessionKey: String,
        requestID: String?,
        messageID: String?,
        timestampMilliseconds: Int,
        metadata: [String: JSONValue]
    ) {
        var messages = messagesBySession[sessionKey, default: []]
        let activeRequestID = activeStreamRequestIDs[sessionKey]
        let isFinalizedDuplicate = messages.last?.role == .assistant
            && messages.last?.isStreaming == false
            && messages.last?.messageID == nil
            && messages.last?.text == content
        let shouldReplaceLast = messages.last?.role == .assistant
            && (
                messages.last?.isStreaming == true
                    || (requestID != nil && requestID == activeRequestID)
                    || isFinalizedDuplicate
            )

        if shouldReplaceLast, let lastIndex = messages.indices.last {
            messages[lastIndex].text = content
            messages[lastIndex].timestampMilliseconds = timestampMilliseconds
            messages[lastIndex].messageID = messageID
            messages[lastIndex].metadata = metadata
            messages[lastIndex].isStreaming = !isFinalizedDuplicate
        } else {
            messages.append(ChatMessage(
                role: .assistant,
                text: content,
                timestampMilliseconds: timestampMilliseconds,
                messageID: messageID,
                metadata: metadata,
                isStreaming: true
            ))
        }
        activeStreamRequestIDs[sessionKey] = requestID
        messagesBySession[sessionKey] = messages
    }

    private func replaceStreamingMessage(
        with content: String,
        sessionKey: String,
        messageID: String?,
        metadata: [String: JSONValue] = [:]
    ) {
        var messages = messagesBySession[sessionKey, default: []]
        if let index = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            messages[index].text = content
            messages[index].messageID = messageID
            messages[index].metadata = metadata
            messages[index].isStreaming = false
        } else {
            messages.append(ChatMessage(role: .assistant, text: content, messageID: messageID, metadata: metadata))
        }
        messagesBySession[sessionKey] = messages
    }

    private func markStreamingDone(sessionKey: String) {
        var messages = messagesBySession[sessionKey, default: []]
        if let index = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            messages[index].isStreaming = false
        }
        messagesBySession[sessionKey] = messages
        activeStreamRequestIDs[sessionKey] = nil
    }

    private func removeEmptyStreamingMessage(sessionKey: String) {
        messagesBySession[sessionKey, default: []].removeAll {
            $0.role == .assistant && $0.isStreaming && $0.text.isEmpty
        }
    }

    private func appendMessage(_ message: ChatMessage, sessionKey: String) {
        messagesBySession[sessionKey, default: []].append(message)
    }

    private func messageExists(_ messageID: String?, sessionKey: String) -> Bool {
        guard let messageID else { return false }
        return messagesBySession[sessionKey, default: []].contains { $0.messageID == messageID }
    }

    private func selectInitialSession(activeSessionKey: String?) {
        let preferred = settings.lastSessionKey ?? selectedSessionKey ?? activeSessionKey
        selectedSessionKey = sessions.first { $0.sessionKey == preferred }?.sessionKey
            ?? sessions.first?.sessionKey
        settings.lastSessionKey = selectedSessionKey
        saveSettings()
        ensureSelectedSessionReady()
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

    private func nowMilliseconds() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
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
