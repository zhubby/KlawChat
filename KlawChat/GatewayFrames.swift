import Foundation

struct ClientMethodFrame: Encodable, Sendable {
    var id: String
    var method: String
    var params: [String: JSONValue]
}

struct ClientNotificationFrame: Encodable, Sendable {
    var method: String
    var params: [String: JSONValue]
}

enum ServerFrame: Equatable, Sendable {
    case result(id: String, result: [String: JSONValue])
    case notification(method: String, params: [String: JSONValue])
    case serverRequest(id: String, method: String, params: [String: JSONValue])
    case error(id: String?, error: ServerErrorFrame)
}

struct ServerErrorFrame: Codable, Equatable, Sendable {
    var code: String
    var message: String
    var data: JSONValue?
}

extension ServerFrame: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case result
        case method
        case params
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.result) {
            self = .result(
                id: try container.decode(String.self, forKey: .id),
                result: try container.decodeIfPresent([String: JSONValue].self, forKey: .result) ?? [:]
            )
            return
        }

        if container.contains(.error) {
            self = .error(
                id: try container.decodeIfPresent(String.self, forKey: .id),
                error: try container.decode(ServerErrorFrame.self, forKey: .error)
            )
            return
        }

        if container.contains(.method) {
            let method = try container.decode(String.self, forKey: .method)
            let params = try container.decodeIfPresent([String: JSONValue].self, forKey: .params) ?? [:]
            if let id = try container.decodeIfPresent(String.self, forKey: .id) {
                self = .serverRequest(id: id, method: method, params: params)
            } else {
                self = .notification(method: method, params: params)
            }
            return
        }

        if container.contains(.id) {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Gateway response must include result or error."
            )
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported gateway frame.")
        )
    }
}
