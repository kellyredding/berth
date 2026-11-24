import Foundation

// MIRROR: tools/berth/src/berth/socket_client.cr (see docs/contract.md,
// "Socket")

enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

enum ErrorCode: String, Codable {
    case badRequest = "bad_request"
    case notPermitted = "not_permitted"
    case notFound = "not_found"
    case unavailable
    case `internal`
}

struct RequestError: Error, Equatable {
    let code: ErrorCode
    let message: String

    static func badRequest(_ message: String) -> RequestError {
        RequestError(code: .badRequest, message: message)
    }

    static let noConfig = RequestError(code: .unavailable, message: "no config is loaded")

    static let signinNotImplemented = RequestError(
        code: .unavailable, message: "signin.fill is not implemented yet"
    )
}

// MARK: - Requests

struct RequestEnvelope: Decodable {
    let v: Int
    let event: String
    let ts: Int64?
    let detailData: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case v, event, ts
        case detailData = "detail_data"
    }
}

/// The socket's events. `signin.fill` carries secrets in its detail, which is
/// why no request is ever logged or kept.
enum BerthRequest: Equatable {
    case status
    case open(URL?)
    case reload
    case signinFill

    static func parse(_ line: Data) -> Result<BerthRequest, RequestError> {
        let envelope: RequestEnvelope
        do {
            envelope = try JSONDecoder().decode(RequestEnvelope.self, from: line)
        } catch {
            return .failure(.badRequest("the request is not a valid envelope"))
        }
        guard envelope.v == 1 else {
            return .failure(.badRequest("unsupported envelope version \(envelope.v)"))
        }
        let detail = envelope.detailData ?? [:]
        switch envelope.event {
        case "status": return .success(.status)
        case "reload": return .success(.reload)
        case "signin.fill": return .success(.signinFill)
        case "open": return parseOpen(detail)
        default: return .failure(.badRequest("unknown event \"\(envelope.event)\""))
        }
    }

    private static func parseOpen(_ detail: [String: JSONValue]) -> Result<BerthRequest, RequestError> {
        switch detail["url"] {
        case nil, .null?:
            return .success(.open(nil))
        case .string(let text)?:
            guard let url = URL(string: text), LinkPolicy.isWeb(url), let host = url.host, !host.isEmpty else {
                return .failure(.badRequest("\(text) is not an http or https URL"))
            }
            return .success(.open(url))
        default:
            return .failure(.badRequest("url must be a string"))
        }
    }
}

// MARK: - Replies

enum ConfigLoadState: String, Encodable {
    case loading, loaded, failed

    init(hasConfig: Bool, finishedFirstLoad: Bool) {
        self = hasConfig ? .loaded : finishedFirstLoad ? .failed : .loading
    }
}

/// Encodes every optional as `null` rather than leaving the key out, so the
/// CLI always sees the same keys.
struct StatusData: Encodable, Equatable {
    struct Config: Encodable, Equatable {
        let state: ConfigLoadState
        let error: String?

        enum CodingKeys: String, CodingKey { case loaded, state, error }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state == .loaded, forKey: .loaded)
            try container.encode(state, forKey: .state)
            try container.encode(error, forKey: .error)
        }
    }

    let version: String
    let pid: Int
    let site: String
    /// The page showing now; null before the first one loads.
    let url: String?
    let title: String?
    let badge: String?
    let config: Config

    enum CodingKeys: String, CodingKey { case version, pid, site, url, title, badge, config }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(pid, forKey: .pid)
        try container.encode(site, forKey: .site)
        try container.encode(url, forKey: .url)
        try container.encode(title, forKey: .title)
        try container.encode(badge, forKey: .badge)
        try container.encode(config, forKey: .config)
    }
}

struct OpenData: Encodable, Equatable {
    enum Destination: String, Encodable { case app, browser }

    let url: String?
    let openedIn: Destination

    enum CodingKeys: String, CodingKey {
        case url
        case openedIn = "opened_in"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(openedIn, forKey: .openedIn)
    }
}

struct ReloadData: Encodable, Equatable {
    let loaded: Bool
    let error: String?

    enum CodingKeys: String, CodingKey { case loaded, error }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(loaded, forKey: .loaded)
        try container.encode(error, forKey: .error)
    }
}

/// One JSON line, without its terminating newline.
enum Reply {
    private struct Success<T: Encodable>: Encodable {
        let ok = true
        let data: T
    }

    private struct Failure: Encodable {
        let ok = false
        let error: String
        let code: ErrorCode
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    static func ok<T: Encodable>(_ data: T) -> Data {
        do {
            return try encoder.encode(Success(data: data))
        } catch {
            return failure(RequestError(code: .internal, message: "could not encode the reply"))
        }
    }

    static func failure(_ error: RequestError) -> Data {
        (try? encoder.encode(Failure(error: error.message, code: error.code)))
            ?? Data(#"{"ok":false,"error":"could not encode the reply","code":"internal"}"#.utf8)
    }
}
