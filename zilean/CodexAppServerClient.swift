import Foundation

enum AppServerTurnStatus: String, Sendable {
    case completed
    case interrupted
    case failed
}

enum AppServerEvent: Sendable {
    case agentMessageDelta(itemID: String, text: String)
    case turnCompleted(status: AppServerTurnStatus, errorMessage: String?)
    case processExited(message: String)
    case protocolError(message: String)
}

enum CodexAppServerError: LocalizedError {
    case executableNotFound
    case notConnected
    case processExited(Int32, String?)
    case protocolFailure(String)
    case requestFailed(String)
    case requestTimedOut(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Codex 실행 파일을 찾을 수 없습니다. Codex CLI를 설치·인증한 뒤 앱을 다시 시도해 주세요."
        case .notConnected:
            "Codex와 연결되어 있지 않습니다. 연결 재시도를 눌러 주세요."
        case let .processExited(status, details):
            if let details, !details.isEmpty {
                "Codex 프로세스가 종료되었습니다(코드 \(status)): \(details) 연결 재시도를 눌러 주세요."
            } else {
                "Codex 프로세스가 종료되었습니다(코드 \(status)). 연결 재시도를 눌러 주세요."
            }
        case let .protocolFailure(message):
            "Codex 응답을 처리하지 못했습니다: \(message) 연결 재시도를 눌러 주세요."
        case let .requestFailed(message):
            "Codex 요청이 실패했습니다: \(message)"
        case let .requestTimedOut(method):
            "Codex가 \(method) 요청에 응답하지 않았습니다. 연결을 다시 시도해 주세요."
        case let .invalidResponse(method):
            "Codex가 \(method) 요청에 올바른 응답을 보내지 않았습니다."
        }
    }
}

@MainActor
protocol CodexAppServerServing: AnyObject {
    var onEvent: ((AppServerEvent) -> Void)? { get set }
    var isConnected: Bool { get }

    func connect() async throws
    func startThread(in directory: URL) async throws -> String
    func startTurn(threadID: String, text: String) async throws -> String
    func stop()
}

struct CodexExecutableLocator {
    private static let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fileManager = FileManager.default
        var candidates: [String] = []

        if let override = environment["CODEX_PATH"], !override.isEmpty {
            candidates.append(override)
        }

        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.bun/bin/codex",
        ])

        let candidate = candidates.lazy
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .first(where: { fileManager.isExecutableFile(atPath: $0.path) })
        if let candidate {
            return candidate
        }

        return locateUsingLoginShell()
    }

    static func processEnvironment(
        for executableURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var processEnvironment = environment
        let executableDirectory = executableURL.deletingLastPathComponent().path
        let inheritedPath = environment["PATH"] ?? defaultPath
        var pathComponents = inheritedPath.split(separator: ":").map(String.init)

        pathComponents.removeAll { $0 == executableDirectory }
        pathComponents.insert(executableDirectory, at: 0)
        processEnvironment["PATH"] = pathComponents.joined(separator: ":")

        return processEnvironment
    }

    private static func locateUsingLoginShell() -> URL? {
        let process = Process()
        let output = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v codex"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            let lines = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map(String.init)

            guard let path = lines.last else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        } catch {
            return nil
        }
    }
}

@MainActor
final class CodexAppServerClient: CodexAppServerServing {
    var onEvent: ((AppServerEvent) -> Void)?

    private var process: Process?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var standardError: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var errorReaderTask: Task<Void, Never>?
    private var responseRouter = JSONRPCResponseRouter()
    private var nextRequestID = 1
    private var stderrText = ""
    private var stopping = false

    var isConnected: Bool {
        process?.isRunning == true
    }

    func connect() async throws {
        stop()

        guard let executableURL = CodexExecutableLocator.locate() else {
            throw CodexAppServerError.executableNotFound
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.environment = CodexExecutableLocator.processEnvironment(for: executableURL)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                self?.handleProcessTermination(status: terminatedProcess.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.protocolFailure(error.localizedDescription)
        }

        self.process = process
        standardInput = inputPipe.fileHandleForWriting
        standardOutput = outputPipe.fileHandleForReading
        standardError = errorPipe.fileHandleForReading
        stopping = false
        stderrText = ""
        startReaders(output: outputPipe.fileHandleForReading, error: errorPipe.fileHandleForReading)

        do {
            _ = try await request(
                method: "initialize",
                params: [
                    "clientInfo": .object([
                        "name": .string("zilean"),
                        "title": .string("Zilean"),
                        "version": .string("0.1.0"),
                    ]),
                ]
            )
            try send(method: "initialized", params: [:])
        } catch {
            stop()
            throw error
        }
    }

    func startThread(in directory: URL) async throws -> String {
        let response = try await request(
            method: "thread/start",
            params: [
                "cwd": .string(directory.path),
                "approvalPolicy": .string("never"),
                "sandbox": .string("read-only"),
            ]
        )

        guard let threadID = response.value(at: "result", "thread", "id")?.stringValue else {
            throw CodexAppServerError.invalidResponse("thread/start")
        }
        return threadID
    }

    func startTurn(threadID: String, text: String) async throws -> String {
        let response = try await request(
            method: "turn/start",
            params: [
                "threadId": .string(threadID),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(text),
                    ]),
                ]),
            ]
        )

        guard let turnID = response.value(at: "result", "turn", "id")?.stringValue else {
            throw CodexAppServerError.invalidResponse("turn/start")
        }
        return turnID
    }

    func stop() {
        guard process != nil || responseRouter.pendingCount > 0 else { return }

        stopping = true
        readerTask?.cancel()
        errorReaderTask?.cancel()
        readerTask = nil
        errorReaderTask = nil
        responseRouter.failAll(with: CodexAppServerError.notConnected)

        try? standardInput?.close()
        try? standardOutput?.close()
        try? standardError?.close()

        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }

        self.process = nil
        standardInput = nil
        standardOutput = nil
        standardError = nil
    }

    private func startReaders(output: FileHandle, error: FileHandle) {
        readerTask = Task.detached { [weak self] in
            var decoder = JSONLMessageDecoder()

            do {
                while !Task.isCancelled, let data = try output.read(upToCount: 4096), !data.isEmpty {
                    let messages = try decoder.append(data)
                    for message in messages {
                        await self?.receive(message)
                    }
                }

                for message in try decoder.finish() {
                    await self?.receive(message)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await self?.receiveProtocolError(error)
            }
        }

        errorReaderTask = Task.detached { [weak self] in
            do {
                while !Task.isCancelled, let data = try error.read(upToCount: 2048), !data.isEmpty {
                    await self?.appendStandardError(data)
                }
            } catch {
                // Closing the pipe during normal shutdown interrupts the read.
            }
        }
    }

    private func request(method: String, params: [String: JSONValue]) async throws -> AppServerMessage {
        guard process?.isRunning == true else {
            throw CodexAppServerError.notConnected
        }

        let id = nextRequestID
        nextRequestID += 1

        return try await withCheckedThrowingContinuation { continuation in
            responseRouter.register(id: id) { result in
                switch result {
                case let .success(message):
                    if let errorMessage = message.value(at: "error", "message")?.stringValue {
                        continuation.resume(throwing: CodexAppServerError.requestFailed(errorMessage))
                    } else {
                        continuation.resume(returning: message)
                    }
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }

            do {
                try write(payload: [
                    "id": .number(Double(id)),
                    "method": .string(method),
                    "params": .object(params),
                ])
            } catch {
                responseRouter.cancel(id: id, error: error)
                return
            }

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.responseRouter.cancel(
                    id: id,
                    error: CodexAppServerError.requestTimedOut(method)
                )
            }
        }
    }

    private func send(method: String, params: [String: JSONValue]) throws {
        try write(payload: [
            "method": .string(method),
            "params": .object(params),
        ])
    }

    private func write(payload: [String: JSONValue]) throws {
        guard let standardInput, process?.isRunning == true else {
            throw CodexAppServerError.notConnected
        }

        var data = try JSONEncoder().encode(JSONValue.object(payload))
        data.append(0x0A)

        do {
            try standardInput.write(contentsOf: data)
        } catch {
            throw CodexAppServerError.protocolFailure(error.localizedDescription)
        }
    }

    private func receive(_ message: AppServerMessage) {
        if message.id != nil {
            guard responseRouter.route(message) else { return }
            return
        }

        switch message.method {
        case "item/agentMessage/delta":
            guard
                let itemID = message.value(at: "params", "itemId")?.stringValue,
                let delta = message.value(at: "params", "delta")?.stringValue
            else { return }
            onEvent?(.agentMessageDelta(itemID: itemID, text: delta))

        case "turn/completed":
            guard
                let rawStatus = message.value(at: "params", "turn", "status")?.stringValue,
                let status = AppServerTurnStatus(rawValue: rawStatus)
            else { return }
            let errorMessage = message.value(at: "params", "turn", "error", "message")?.stringValue
            onEvent?(.turnCompleted(status: status, errorMessage: errorMessage))

        default:
            break
        }
    }

    private func receiveProtocolError(_ error: Error) {
        guard !stopping else { return }
        let message = CodexAppServerError.protocolFailure(error.localizedDescription).localizedDescription
        responseRouter.failAll(with: CodexAppServerError.protocolFailure(error.localizedDescription))
        onEvent?(.protocolError(message: message))
        stop()
    }

    private func appendStandardError(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        stderrText.append(text)
        if stderrText.count > 4_000 {
            stderrText = String(stderrText.suffix(4_000))
        }
    }

    private func handleProcessTermination(status: Int32) {
        let wasStopping = stopping
        process = nil
        standardInput = nil
        standardOutput = nil
        standardError = nil

        guard !wasStopping else { return }

        let details = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = CodexAppServerError.processExited(status, details.isEmpty ? nil : details)
        responseRouter.failAll(with: error)
        onEvent?(.processExited(message: error.localizedDescription))
    }
}
