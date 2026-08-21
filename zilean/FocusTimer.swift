import Foundation

nonisolated enum FocusTimerStatus: String, Codable, Equatable, Sendable {
    case running
    case completed
}

nonisolated struct FocusTimerSession: Identifiable, Equatable, Sendable {
    let id: UUID
    let workID: UUID
    let taskTitle: String
    let durationMinutes: Int
    let startedAt: Date
    var status: FocusTimerStatus
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        workID: UUID,
        taskTitle: String,
        durationMinutes: Int,
        startedAt: Date = .now,
        status: FocusTimerStatus = .running,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.workID = workID
        self.taskTitle = taskTitle
        self.durationMinutes = durationMinutes
        self.startedAt = startedAt
        self.status = status
        self.completedAt = completedAt
    }

    var targetEndAt: Date {
        startedAt.addingTimeInterval(TimeInterval(durationMinutes * 60))
    }

    func elapsed(at now: Date) -> TimeInterval {
        max(0, (completedAt ?? now).timeIntervalSince(startedAt))
    }

    func progress(at now: Date) -> Double {
        min(1, elapsed(at: now) / TimeInterval(durationMinutes * 60))
    }
}

nonisolated struct ZileanMCPCommand: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case startFocusTimer
    }

    let id: UUID
    let kind: Kind
    let taskTitle: String
    let durationMinutes: Int
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: Kind = .startFocusTimer,
        taskTitle: String,
        durationMinutes: Int,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.taskTitle = taskTitle
        self.durationMinutes = durationMinutes
        self.createdAt = createdAt
    }
}

nonisolated struct ZileanMCPCommandResponse: Codable, Equatable, Sendable {
    let id: UUID
    let success: Bool
    let taskTitle: String?
    let durationMinutes: Int?
    let startedAt: Date?
    let targetEndAt: Date?
    let state: String?
    let errorCode: String?
    let message: String

    static func started(command: ZileanMCPCommand, session: FocusTimerSession) -> Self {
        Self(
            id: command.id,
            success: true,
            taskTitle: session.taskTitle,
            durationMinutes: session.durationMinutes,
            startedAt: session.startedAt,
            targetEndAt: session.targetEndAt,
            state: session.status.rawValue,
            errorCode: nil,
            message: "집중 타이머를 시작했습니다."
        )
    }

    static func failed(commandID: UUID, code: String, message: String) -> Self {
        Self(
            id: commandID,
            success: false,
            taskTitle: nil,
            durationMinutes: nil,
            startedAt: nil,
            targetEndAt: nil,
            state: nil,
            errorCode: code,
            message: message
        )
    }
}

nonisolated struct ZileanMCPCommandStore {
    let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    var requestsDirectory: URL {
        rootDirectory.appendingPathComponent("requests", isDirectory: true)
    }

    var responsesDirectory: URL {
        rootDirectory.appendingPathComponent("responses", isDirectory: true)
    }

    func prepare() throws {
        try fileManager.createDirectory(
            at: requestsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try fileManager.createDirectory(
            at: responsesDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    func enqueue(_ command: ZileanMCPCommand) throws {
        try prepare()
        try encoder().encode(command).write(to: requestURL(for: command.id), options: .atomic)
    }

    func pendingCommands() throws -> [ZileanMCPCommand] {
        try prepare()
        return try fileManager.contentsOfDirectory(
            at: requestsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder().decode(ZileanMCPCommand.self, from: data)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func writeResponse(_ response: ZileanMCPCommandResponse) throws {
        try prepare()
        try encoder().encode(response).write(to: responseURL(for: response.id), options: .atomic)
    }

    func readResponse(for commandID: UUID) throws -> ZileanMCPCommandResponse? {
        let url = responseURL(for: commandID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder().decode(ZileanMCPCommandResponse.self, from: Data(contentsOf: url))
    }

    func removeRequest(for commandID: UUID) throws {
        let url = requestURL(for: commandID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func removeResponse(for commandID: UUID) throws {
        let url = responseURL(for: commandID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func submit(
        _ command: ZileanMCPCommand,
        timeout: TimeInterval = 5,
        pollingInterval: TimeInterval = 0.05
    ) -> ZileanMCPCommandResponse {
        do {
            try enqueue(command)
            let deadline = Date().addingTimeInterval(timeout)

            while Date() < deadline {
                if let response = try readResponse(for: command.id) {
                    try? removeResponse(for: command.id)
                    return response
                }
                Thread.sleep(forTimeInterval: pollingInterval)
            }

            try? removeRequest(for: command.id)
            return .failed(
                commandID: command.id,
                code: "app_unavailable",
                message: "Zilean 앱이 타이머 시작 요청에 응답하지 않았습니다."
            )
        } catch {
            try? removeRequest(for: command.id)
            return .failed(
                commandID: command.id,
                code: "bridge_failure",
                message: "Zilean 앱에 타이머 시작 요청을 전달하지 못했습니다."
            )
        }
    }

    private func requestURL(for id: UUID) -> URL {
        requestsDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func responseURL(for id: UUID) -> URL {
        responsesDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
