import Foundation

struct ClientMethodFrame: Encodable, Sendable {
    var type = "method"
    var id: String
    var method: String
    var params: [String: JSONValue]
}

enum ServerFrame: Equatable, Sendable {
    case result(id: String, result: [String: JSONValue])
    case event(event: String, payload: [String: JSONValue])
    case error(id: String?, error: ServerErrorFrame)
}

struct ServerErrorFrame: Codable, Equatable, Sendable {
    var code: String
    var message: String
    var data: JSONValue?
}

extension ServerFrame: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case result
        case event
        case payload
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type).lowercased()
        switch type {
        case "result":
            self = .result(
                id: try container.decode(String.self, forKey: .id),
                result: try container.decodeIfPresent([String: JSONValue].self, forKey: .result) ?? [:]
            )
        case "event":
            self = .event(
                event: try container.decode(String.self, forKey: .event),
                payload: try container.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
            )
        case "error":
            self = .error(
                id: try container.decodeIfPresent(String.self, forKey: .id),
                error: try container.decode(ServerErrorFrame.self, forKey: .error)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported server frame type: \(type)"
            )
        }
    }
}
