import Foundation

enum BridgeOutbound: Encodable {
    case createSession(id: String, model: String, systemPrompt: String?)
    case send(id: String, text: String)
    case endSession(id: String)

    private enum CodingKeys: String, CodingKey {
        case type, id, model, text
        case systemPrompt = "system_prompt"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .createSession(let id, let model, let systemPrompt):
            try c.encode("create_session", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(model, forKey: .model)
            try c.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
        case .send(let id, let text):
            try c.encode("send", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
        case .endSession(let id):
            try c.encode("end_session", forKey: .type)
            try c.encode(id, forKey: .id)
        }
    }
}

enum BridgeInbound: Decodable {
    case sessionCreated(id: String)
    case delta(id: String, text: String)
    case done(id: String)
    case error(id: String, message: String)

    private enum CodingKeys: String, CodingKey {
        case type, id, text, message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let id = try c.decode(String.self, forKey: .id)
        switch type {
        case "session_created": self = .sessionCreated(id: id)
        case "delta":           self = .delta(id: id, text: try c.decode(String.self, forKey: .text))
        case "done":            self = .done(id: id)
        case "error":           self = .error(id: id, message: try c.decode(String.self, forKey: .message))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                    debugDescription: "unknown type \(type)")
        }
    }
}
