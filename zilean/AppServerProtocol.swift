import Foundation

nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

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
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard case let .number(value) = self, value.rounded() == value else { return nil }
        return Int(value)
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }
}

nonisolated struct AppServerMessage: Equatable, Sendable {
    let payload: [String: JSONValue]

    init(payload: [String: JSONValue]) {
        self.payload = payload
    }

    init(data: Data) throws {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let payload = decoded.objectValue else {
            throw AppServerProtocolError.expectedObject
        }
        self.payload = payload
    }

    var id: Int? { payload["id"]?.integerValue }
    var method: String? { payload["method"]?.stringValue }
    var result: JSONValue? { payload["result"] }
    var error: JSONValue? { payload["error"] }

    func value(at path: String...) -> JSONValue? {
        value(at: path)
    }

    func value(at path: [String]) -> JSONValue? {
        var current: JSONValue = .object(payload)

        for component in path {
            guard let object = current.objectValue, let next = object[component] else {
                return nil
            }
            current = next
        }

        return current
    }
}

nonisolated enum AppServerProtocolError: LocalizedError, Equatable {
    case expectedObject
    case incompleteTrailingMessage

    var errorDescription: String? {
        switch self {
        case .expectedObject:
            "app-server가 JSON 객체가 아닌 응답을 보냈습니다."
        case .incompleteTrailingMessage:
            "app-server 응답이 완성되기 전에 연결이 종료되었습니다."
        }
    }
}

nonisolated struct JSONLMessageDecoder {
    private var buffer = Data()

    mutating func append(_ chunk: Data) throws -> [AppServerMessage] {
        buffer.append(chunk)
        var messages: [AppServerMessage] = []

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)

            if line.last == 0x0D {
                line.removeLast()
            }
            guard !line.isEmpty else { continue }

            messages.append(try AppServerMessage(data: line))
        }

        return messages
    }

    mutating func finish() throws -> [AppServerMessage] {
        guard !buffer.isEmpty else { return [] }
        defer { buffer.removeAll(keepingCapacity: false) }

        var line = buffer
        if line.last == 0x0D {
            line.removeLast()
        }
        guard !line.isEmpty else { return [] }

        do {
            return [try AppServerMessage(data: line)]
        } catch DecodingError.dataCorrupted {
            throw AppServerProtocolError.incompleteTrailingMessage
        } catch {
            throw error
        }
    }
}

nonisolated struct JSONRPCResponseRouter {
    typealias Handler = (Result<AppServerMessage, Error>) -> Void

    private var pending: [Int: Handler] = [:]

    var pendingCount: Int { pending.count }

    mutating func register(id: Int, handler: @escaping Handler) {
        pending[id] = handler
    }

    @discardableResult
    mutating func route(_ message: AppServerMessage) -> Bool {
        guard let id = message.id, let handler = pending.removeValue(forKey: id) else {
            return false
        }

        handler(.success(message))
        return true
    }

    @discardableResult
    mutating func cancel(id: Int, error: Error) -> Bool {
        guard let handler = pending.removeValue(forKey: id) else { return false }
        handler(.failure(error))
        return true
    }

    mutating func failAll(with error: Error) {
        let handlers = pending.values
        pending.removeAll()
        handlers.forEach { $0(.failure(error)) }
    }
}
