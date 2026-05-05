import Foundation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var label: String {
        switch self {
        case .disconnected:
            return "Offline"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Ready"
        case .error:
            return "Error"
        }
    }
}

enum MessageRole: String, Codable, Equatable, Sendable {
    case system
    case assistant
    case user
}

struct WorkspaceSession: Identifiable, Codable, Equatable, Sendable {
    var sessionKey: String
    var title: String
    var createdAtMilliseconds: Int
    var modelProvider: String?
    var model: String?

    var id: String { sessionKey }

    enum CodingKeys: String, CodingKey {
        case sessionKey = "session_key"
        case title
        case createdAtMilliseconds = "created_at_ms"
        case modelProvider = "model_provider"
        case model
    }

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Agent" : title
    }
}

struct Provider: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String?
    var defaultModel: String
    var stream: Bool?
    var hasAPIKey: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case defaultModel = "default_model"
        case stream
        case hasAPIKey = "has_api_key"
    }
}

struct ProviderCatalog: Equatable, Sendable {
    var defaultProvider: String?
    var providers: [Provider]

    static let empty = ProviderCatalog(defaultProvider: nil, providers: [])

    func resolvedRoute(provider requestedProvider: String?, model requestedModel: String?) -> ModelRoute {
        let provider = requestedProvider?.nilIfBlank
            ?? defaultProvider?.nilIfBlank
            ?? providers.first?.id
            ?? ""
        let model = requestedModel?.nilIfBlank
            ?? providers.first(where: { $0.id == provider })?.defaultModel
            ?? ""
        return ModelRoute(provider: provider, model: model)
    }
}

struct ModelRoute: Equatable, Sendable {
    var provider: String
    var model: String
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    var id: String
    var role: MessageRole
    var text: String
    var timestampMilliseconds: Int
    var messageID: String?
    var metadata: [String: JSONValue]
    var isStreaming: Bool

    init(
        id: String = UUID().uuidString,
        role: MessageRole,
        text: String,
        timestampMilliseconds: Int = Int(Date().timeIntervalSince1970 * 1000),
        messageID: String? = nil,
        metadata: [String: JSONValue] = [:],
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestampMilliseconds = timestampMilliseconds
        self.messageID = messageID
        self.metadata = metadata
        self.isStreaming = isStreaming
    }

    var interactionCard: InteractionCard? {
        InteractionCard.resolve(content: text, metadata: metadata)
    }
}

extension ChatMessage {
    func relativeTimestampText(nowMilliseconds: Int = Int(Date().timeIntervalSince1970 * 1000)) -> String {
        let elapsedSeconds = max(0, (nowMilliseconds - timestampMilliseconds) / 1000)
        if elapsedSeconds < 1 {
            return "just now"
        }
        if elapsedSeconds < 60 {
            return "\(elapsedSeconds) \(elapsedSeconds == 1 ? "second" : "seconds") ago"
        }

        let elapsedMinutes = elapsedSeconds / 60
        if elapsedMinutes < 60 {
            return "\(elapsedMinutes) \(elapsedMinutes == 1 ? "minute" : "minutes") ago"
        }

        let elapsedHours = elapsedMinutes / 60
        if elapsedHours < 24 {
            return "\(elapsedHours) \(elapsedHours == 1 ? "hour" : "hours") ago"
        }

        let elapsedDays = elapsedHours / 24
        return "\(elapsedDays) \(elapsedDays == 1 ? "day" : "days") ago"
    }
}

enum InteractionCardKind: String, Equatable, Sendable {
    case approval
    case questionSingleSelect = "question_single_select"
}

struct InteractionCardAction: Equatable, Sendable {
    var label: String
    var command: String
}

struct InteractionCard: Equatable, Sendable {
    var kind: InteractionCardKind
    var title: String
    var body: String
    var approvalID: String?
    var commandPreview: String?
    var actions: [InteractionCardAction]

    static func resolve(content: String, metadata: [String: JSONValue]) -> InteractionCard? {
        explicitCard(from: metadata.object("im.card"), fallbackContent: content)
            ?? approvalCard(content: content, metadata: metadata)
    }

    private static func explicitCard(from object: [String: JSONValue]?, fallbackContent: String) -> InteractionCard? {
        guard let object,
              let kindValue = object.string("kind"),
              let kind = InteractionCardKind(rawValue: kindValue) else {
            return nil
        }

        let cardMetadata = object.object("metadata") ?? [:]
        let fallbackBody = object.string("fallback_text") ?? fallbackContent
        let body = object.string("body")?.nilIfBlank ?? fallbackBody.nilIfBlank ?? ""
        let approvalID = approvalID(in: cardMetadata)
            ?? object.array("actions")?.compactMap { actionApprovalID($0.objectValue) }.first
        let title = object.string("title")?.nilIfBlank ?? defaultTitle(for: kind)
        return InteractionCard(
            kind: kind,
            title: title,
            body: body,
            approvalID: approvalID,
            commandPreview: cardMetadata.string("command_preview"),
            actions: actions(from: object.array("actions"), approvalID: approvalID)
        )
    }

    private static func approvalCard(content: String, metadata: [String: JSONValue]) -> InteractionCard? {
        let signal = metadata.object("approval.signal")
        guard let approvalID = approvalID(in: metadata)
            ?? signal?.string("approval_id")?.nilIfBlank
            ?? extractApprovalID(from: content) else {
            return nil
        }

        return InteractionCard(
            kind: .approval,
            title: defaultTitle(for: .approval),
            body: content.trimmingCharacters(in: .whitespacesAndNewlines),
            approvalID: approvalID,
            commandPreview: signal?.string("command_preview")?.nilIfBlank,
            actions: [
                InteractionCardAction(label: "Approve", command: "/approve \(approvalID)"),
                InteractionCardAction(label: "Reject", command: "/reject \(approvalID)")
            ]
        )
    }

    private static func actions(from values: [JSONValue]?, approvalID: String?) -> [InteractionCardAction] {
        values?.compactMap { value in
            guard let object = value.objectValue,
                  let kind = object.string("kind") else {
                return nil
            }
            let label = object.string("label")?.nilIfBlank ?? defaultActionLabel(for: kind)
            switch kind {
            case "approve":
                guard let approvalID = actionApprovalID(object) ?? approvalID else { return nil }
                return InteractionCardAction(label: label, command: "/approve \(approvalID)")
            case "reject":
                guard let approvalID = actionApprovalID(object) ?? approvalID else { return nil }
                return InteractionCardAction(label: label, command: "/reject \(approvalID)")
            case "submit_command":
                guard let command = object.string("command")?.nilIfBlank else { return nil }
                return InteractionCardAction(label: label, command: command)
            default:
                return nil
            }
        } ?? []
    }

    private static func approvalID(in metadata: [String: JSONValue]) -> String? {
        metadata.string("approval_id")?.nilIfBlank
            ?? metadata.string("approval.id")?.nilIfBlank
    }

    private static func actionApprovalID(_ object: [String: JSONValue]?) -> String? {
        object?.string("value")?.nilIfBlank
    }

    private static func extractApprovalID(from content: String) -> String? {
        guard let range = content.range(of: "approval_id=") else {
            return nil
        }
        let suffix = content[range.upperBound...]
        let token = suffix.prefix { character in
            character.isLetter || character.isNumber || character == "-"
        }
        return token.isEmpty ? nil : String(token)
    }

    private static func defaultTitle(for kind: InteractionCardKind) -> String {
        switch kind {
        case .approval:
            return "Approval Required"
        case .questionSingleSelect:
            return "Question"
        }
    }

    private static func defaultActionLabel(for kind: String) -> String {
        switch kind {
        case "approve":
            return "Approve"
        case "reject":
            return "Reject"
        default:
            return "Select"
        }
    }
}

struct ArchiveAttachment: Codable, Equatable, Sendable {
    var archiveID: String
    var filename: String?
    var mimeType: String?
    var sizeBytes: Int

    enum CodingKeys: String, CodingKey {
        case archiveID = "archive_id"
        case filename
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
    }
}

struct TurnReference: Equatable, Sendable {
    var sessionID: String
    var threadID: String
    var turnID: String
}

struct ApprovalResponse: Equatable, Sendable {
    var requestID: String
    var threadID: String
    var turnID: String
    var decision: String
}

struct PendingServerRequest: Identifiable, Equatable, Sendable {
    var requestID: String
    var method: String
    var threadID: String
    var turnID: String
    var prompt: String
    var scope: String?
    var params: [String: JSONValue]

    var id: String { requestID }

    var isUserInputRequest: Bool {
        method == "tool/requestUserInput" || method == "user_input/request"
    }

    var kindLabel: String {
        switch method {
        case "approval/request":
            return "Approval"
        case "tool/request":
            return "Tool Request"
        case _ where isUserInputRequest:
            return "Input Requested"
        default:
            return "Server Request"
        }
    }
}

extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
