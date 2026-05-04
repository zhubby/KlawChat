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
