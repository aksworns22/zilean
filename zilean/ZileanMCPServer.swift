import Foundation

nonisolated struct ZileanMCPProtocol {
    static let statusToolName = "zilean_status"
    static let startTimerToolName = "start_focus_timer"

    let configurationDirectory: URL

    private var commandStore: ZileanMCPCommandStore {
        ZileanMCPCommandStore(rootDirectory: configurationDirectory)
    }

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
                        "Zilean의 앱 상태와 집중 타이머를 제공한다. 사용자가 작업명과 추천 시간에 명시적으로 동의한 뒤에만 start_focus_timer를 호출한다. 도구가 성공하기 전에는 타이머가 시작되었다고 말하지 않는다. 상태 확인은 zilean_status를 사용한다."
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
                        statusTool,
                        startTimerTool,
                    ]),
                ]
            )

        case "tools/call":
            switch request.value(at: "params", "name")?.stringValue {
            case Self.statusToolName:
                return statusToolResponse(id: id)
            case Self.startTimerToolName:
                return startTimerResponse(id: id, request: request)
            default:
                return failure(id: id, code: -32602, message: "지원하지 않는 Zilean 도구입니다.")
            }

        default:
            return failure(id: id, code: -32601, message: "지원하지 않는 MCP 메서드입니다.")
        }
    }

    private var statusTool: JSONValue {
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
        ])
    }

    private var startTimerTool: JSONValue {
        .object([
            "name": .string(Self.startTimerToolName),
            "title": .string("집중 타이머 시작"),
            "description": .string(
                "사용자가 작업명과 집중 시간에 명시적으로 동의한 뒤 Zilean 앱의 집중 타이머를 시작한다."
            ),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "taskTitle": .object([
                        "type": .string("string"),
                        "description": .string("사용자와 합의한 작업명"),
                        "minLength": .number(1),
                        "maxLength": .number(120),
                    ]),
                    "durationMinutes": .object([
                        "type": .string("integer"),
                        "description": .string("사용자와 합의한 집중 시간(분)"),
                        "minimum": .number(1),
                        "maximum": .number(1_440),
                    ]),
                ]),
                "required": .array([.string("taskTitle"), .string("durationMinutes")]),
                "additionalProperties": .bool(false),
            ]),
            "annotations": .object([
                "readOnlyHint": .bool(false),
                "destructiveHint": .bool(false),
                "idempotentHint": .bool(false),
                "openWorldHint": .bool(false),
            ]),
        ])
    }

    private func statusToolResponse(id: JSONValue) -> [String: JSONValue] {
        toolResult(
            id: id,
            structuredContent: [
                "connected": .bool(true),
                "configurationDirectory": .string(configurationDirectory.path),
            ],
            message: "Zilean MCP 서버가 연결되어 있습니다.",
            isError: false
        )
    }

    private func startTimerResponse(
        id: JSONValue,
        request: AppServerMessage
    ) -> [String: JSONValue] {
        let taskTitle = (
            request.value(at: "params", "arguments", "taskTitle")?.stringValue ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskTitle.isEmpty, taskTitle.count <= 120 else {
            return toolResult(
                id: id,
                structuredContent: ["errorCode": .string("invalid_task_title")],
                message: "작업명은 1자 이상 120자 이하여야 합니다.",
                isError: true
            )
        }

        guard
            let durationMinutes = request.value(
                at: "params", "arguments", "durationMinutes"
            )?.integerValue,
            (1...1_440).contains(durationMinutes)
        else {
            return toolResult(
                id: id,
                structuredContent: ["errorCode": .string("invalid_duration")],
                message: "집중 시간은 1분 이상 1,440분 이하여야 합니다.",
                isError: true
            )
        }

        let command = ZileanMCPCommand(
            taskTitle: taskTitle,
            durationMinutes: durationMinutes
        )
        let response = commandStore.submit(command)
        var structuredContent: [String: JSONValue] = [
            "success": .bool(response.success),
            "message": .string(response.message),
        ]
        if let taskTitle = response.taskTitle {
            structuredContent["taskTitle"] = .string(taskTitle)
        }
        if let durationMinutes = response.durationMinutes {
            structuredContent["durationMinutes"] = .number(Double(durationMinutes))
        }
        if let startedAt = response.startedAt {
            structuredContent["startedAt"] = .string(ISO8601DateFormatter().string(from: startedAt))
        }
        if let targetEndAt = response.targetEndAt {
            structuredContent["targetEndAt"] = .string(ISO8601DateFormatter().string(from: targetEndAt))
        }
        if let state = response.state {
            structuredContent["state"] = .string(state)
        }
        if let errorCode = response.errorCode {
            structuredContent["errorCode"] = .string(errorCode)
        }

        return toolResult(
            id: id,
            structuredContent: structuredContent,
            message: response.message,
            isError: !response.success
        )
    }

    private func toolResult(
        id: JSONValue,
        structuredContent: [String: JSONValue],
        message: String,
        isError: Bool
    ) -> [String: JSONValue] {
        let encoded = encodedJSONString(.object(structuredContent)) ?? message
        return success(
            id: id,
            result: [
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(encoded),
                    ]),
                ]),
                "structuredContent": .object(structuredContent),
                "isError": .bool(isError),
            ]
        )
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
