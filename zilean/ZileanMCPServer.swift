import Foundation

nonisolated struct ZileanMCPProtocol {
    static let statusToolName = "zilean_status"

    let configurationDirectory: URL

    func response(to request: AppServerMessage) -> [String: JSONValue]? {
        guard let id = request.payload["id"] else { return nil }

        switch request.method {
        case "initialize":
            let requestedVersion = request.value(at: "params", "protocolVersion")?.stringValue
                ?? "2025-06-18"
            return success(
                id: id,
                result: [
                    "protocolVersion": .string(requestedVersion),
                    "capabilities": .object([
                        "tools": .object(["listChanged": .bool(false)]),
                    ]),
                    "serverInfo": .object([
                        "name": .string("zilean"),
                        "title": .string("Zilean"),
                        "version": .string("0.1.0"),
                    ]),
                    "instructions": .string(
                        "Zilean의 앱 상태와 시간 관리 기능을 제공한다. 상태 확인은 zilean_status를 사용한다."
                    ),
                ]
            )

        case "ping":
            return success(id: id, result: [:])

        case "tools/list":
            return success(
                id: id,
                result: [
                    "tools": .array([
                        .object([
                            "name": .string(Self.statusToolName),
                            "title": .string("Zilean 연결 상태"),
                            "description": .string("Zilean 앱의 로컬 MCP 연결 상태를 확인한다."),
                            "inputSchema": .object([
                                "type": .string("object"),
                                "properties": .object([:]),
                                "additionalProperties": .bool(false),
                            ]),
                            "annotations": .object([
                                "readOnlyHint": .bool(true),
                                "destructiveHint": .bool(false),
                                "idempotentHint": .bool(true),
                                "openWorldHint": .bool(false),
                            ]),
                        ]),
                    ]),
                ]
            )

        case "tools/call":
            guard request.value(at: "params", "name")?.stringValue == Self.statusToolName else {
                return failure(id: id, code: -32602, message: "지원하지 않는 Zilean 도구입니다.")
            }

            let status: [String: JSONValue] = [
                "connected": .bool(true),
                "configurationDirectory": .string(configurationDirectory.path),
            ]
            let text = encodedJSONString(.object(status)) ?? "{\"connected\":true}"
            return success(
                id: id,
                result: [
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string(text),
                        ]),
                    ]),
                    "structuredContent": .object(status),
                    "isError": .bool(false),
                ]
            )

        default:
            return failure(id: id, code: -32601, message: "지원하지 않는 MCP 메서드입니다.")
        }
    }

    private func success(id: JSONValue, result: [String: JSONValue]) -> [String: JSONValue] {
        [
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": .object(result),
        ]
    }

    private func failure(id: JSONValue, code: Int, message: String) -> [String: JSONValue] {
        [
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
        ]
    }

    private func encodedJSONString(_ value: JSONValue) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

nonisolated enum ZileanMCPServer {
    static let commandLineFlag = "--zilean-mcp-server"

    static var shouldRun: Bool {
        CommandLine.arguments.contains(commandLineFlag)
    }

    static func run(arguments: [String] = CommandLine.arguments) {
        let configurationDirectory = argument(
            named: "--configuration-directory",
            in: arguments
        ).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("Zilean-MCP", isDirectory: true)
        let protocolHandler = ZileanMCPProtocol(configurationDirectory: configurationDirectory)

        while let line = readLine() {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }

            let response: [String: JSONValue]
            do {
                let request = try AppServerMessage(data: data)
                guard let handled = protocolHandler.response(to: request) else { continue }
                response = handled
            } catch {
                response = [
                    "jsonrpc": .string("2.0"),
                    "id": .null,
                    "error": .object([
                        "code": .number(-32700),
                        "message": .string("MCP 요청을 JSON으로 해석할 수 없습니다."),
                    ]),
                ]
            }

            guard var output = try? JSONEncoder().encode(JSONValue.object(response)) else { continue }
            output.append(0x0A)
            try? FileHandle.standardOutput.write(contentsOf: output)
        }
    }

    private static func argument(named name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }
}
