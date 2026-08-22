import Combine
import Foundation

struct ConversationMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case agent
    }

    let id: UUID
    let role: Role
    var text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

struct WorkSession: Identifiable, Equatable {
    let id: UUID
    let threadID: String
    let directory: URL
    var title: String
    let startedAt: Date
    var updatedAt: Date
    var messages: [ConversationMessage]
    var focusTimer: FocusTimerSession?

    init(
        id: UUID = UUID(),
        threadID: String,
        directory: URL,
        title: String,
        startedAt: Date = .now,
        updatedAt: Date = .now,
        messages: [ConversationMessage] = [],
        focusTimer: FocusTimerSession? = nil
    ) {
        self.id = id
        self.threadID = threadID
        self.directory = directory
        self.title = title
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.focusTimer = focusTimer
    }
}

enum ConversationPhase: Equatable {
    case disconnected
    case connecting
    case ready
    case creatingConversation
    case idle
    case responding
    case completed
    case failed(String)

    var detail: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }

    var isBusy: Bool {
        switch self {
        case .connecting, .creatingConversation, .responding:
            true
        default:
            false
        }
    }
}

@MainActor
final class ConversationViewModel: ObservableObject {
    @Published private(set) var phase: ConversationPhase = .disconnected
    @Published private(set) var workSessions: [WorkSession] = []
    @Published private(set) var activeWorkID: UUID?
    @Published private(set) var selectedDirectory: URL?
    @Published private(set) var focusTimer: FocusTimerSession?
    @Published var draft = ""

    private let client: CodexAppServerServing
    private let harnessPreparer: CodexHarnessPreparing
    private let timerCommandStore: ZileanMCPCommandStore
    private var activeAgentItemID: String?
    private var timerMonitorTask: Task<Void, Never>?
    private var pendingTimerResponses: [UUID: ZileanMCPCommandResponse] = [:]

    var activeWork: WorkSession? {
        guard let activeWorkID else { return nil }
        return workSessions.first { $0.id == activeWorkID }
    }

    var recentWorkSessions: [WorkSession] {
        workSessions
            .compactMap { work in
                work.focusTimer.map { (work: work, timer: $0) }
            }
            .sorted { $0.timer.startedAt > $1.timer.startedAt }
            .map(\.work)
    }

    var messages: [ConversationMessage] {
        activeWork?.messages ?? []
    }

    var canCreateConversation: Bool {
        selectedDirectory != nil && client.isConnected && !phase.isBusy
    }

    var hasConversation: Bool {
        activeWork != nil
    }

    var canSend: Bool {
        activeWork != nil
            && client.isConnected
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !phase.isBusy
    }

    var canRetryConnection: Bool {
        !client.isConnected && !phase.isBusy
    }

    convenience init() {
        let mcpConfiguration = ZileanMCPConfiguration()
        self.init(
            client: CodexAppServerClient(mcpConfiguration: mcpConfiguration),
            harnessPreparer: CodexHarnessPreparer(),
            timerCommandStore: ZileanMCPCommandStore(
                rootDirectory: mcpConfiguration.rootDirectory
            )
        )
    }

    convenience init(client: CodexAppServerServing) {
        self.init(
            client: client,
            harnessPreparer: CodexHarnessPreparer(),
            timerCommandStore: ZileanMCPCommandStore(
                rootDirectory: ZileanMCPConfiguration().rootDirectory
            )
        )
    }

    init(
        client: CodexAppServerServing,
        harnessPreparer: CodexHarnessPreparing,
        timerCommandStore: ZileanMCPCommandStore = ZileanMCPCommandStore(
            rootDirectory: ZileanMCPConfiguration().rootDirectory
        )
    ) {
        self.client = client
        self.harnessPreparer = harnessPreparer
        self.timerCommandStore = timerCommandStore
        client.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    func connect() async {
        guard !client.isConnected else {
            if activeWorkID == nil {
                phase = .ready
            }
            return
        }

        phase = .connecting
        do {
            try await client.connect()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func selectDirectory(_ directory: URL) {
        selectedDirectory = directory.standardizedFileURL
    }

    func startTimerMonitoring() {
        guard timerMonitorTask == nil else { return }

        do {
            try timerCommandStore.prepare()
        } catch {
            phase = .failed("타이머 요청 폴더를 준비하지 못했습니다: \(error.localizedDescription)")
            return
        }

        timerMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.processPendingTimerCommands()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func createConversation() async {
        guard let selectedDirectory, client.isConnected else { return }

        phase = .creatingConversation
        do {
            try harnessPreparer.prepare(in: selectedDirectory)
            let threadID = try await client.startThread(in: selectedDirectory)
            let now = Date.now
            let session = WorkSession(
                threadID: threadID,
                directory: selectedDirectory,
                title: selectedDirectory.lastPathComponent,
                startedAt: now,
                updatedAt: now
            )
            workSessions.append(session)
            activeWorkID = session.id
            activeAgentItemID = nil
            draft = ""
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func sendMessage() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let activeWorkIndex, !text.isEmpty, !phase.isBusy, client.isConnected else { return }

        let threadID = workSessions[activeWorkIndex].threadID

        draft = ""
        activeAgentItemID = nil
        if workSessions[activeWorkIndex].messages.isEmpty {
            workSessions[activeWorkIndex].title = title(from: text)
        }
        workSessions[activeWorkIndex].messages.append(ConversationMessage(role: .user, text: text))
        workSessions[activeWorkIndex].updatedAt = .now
        phase = .responding

        do {
            _ = try await client.startTurn(threadID: threadID, text: text)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func selectWork(id: UUID) {
        guard !phase.isBusy, let session = workSessions.first(where: { $0.id == id }) else { return }

        activeWorkID = session.id
        selectedDirectory = session.directory
        activeAgentItemID = nil
        draft = ""
        if client.isConnected {
            phase = .idle
        }
    }

    func shutdown() {
        timerMonitorTask?.cancel()
        timerMonitorTask = nil
        client.stop()
        activeAgentItemID = nil
        phase = .disconnected
    }

    func processPendingTimerCommands(now: Date = .now) {
        let commands: [ZileanMCPCommand]
        do {
            commands = try timerCommandStore.pendingCommands()
        } catch {
            phase = .failed("타이머 시작 요청을 읽지 못했습니다: \(error.localizedDescription)")
            return
        }

        for command in commands {
            let response = pendingTimerResponses[command.id]
                ?? handleTimerCommand(command, now: now)
            pendingTimerResponses[command.id] = response

            do {
                try timerCommandStore.writeResponse(response)
                try timerCommandStore.removeRequest(for: command.id)
                pendingTimerResponses[command.id] = nil
            } catch {
                phase = .failed("타이머 시작 결과를 전달하지 못했습니다: \(error.localizedDescription)")
            }
        }
    }

    func completeFocusTimer(at date: Date = .now) {
        guard var timer = focusTimer, timer.status == .running else { return }
        timer.status = .completed
        timer.completedAt = date
        focusTimer = timer
        updateFocusTimer(timer)
    }

    func dismissCompletedFocusTimer() {
        guard focusTimer?.status == .completed else { return }
        focusTimer = nil
    }

    func handle(_ event: AppServerEvent) {
        switch event {
        case let .agentMessageDelta(itemID, text):
            mergeAgentDelta(itemID: itemID, text: text)

        case let .turnCompleted(status, errorMessage):
            activeAgentItemID = nil
            switch status {
            case .completed:
                phase = .completed
            case .interrupted:
                phase = .failed("Codex 응답이 중단되었습니다. 메시지를 다시 보내 주세요.")
            case .failed:
                phase = .failed(errorMessage ?? "Codex가 응답을 완료하지 못했습니다. 다시 시도해 주세요.")
            }

        case let .processExited(message), let .protocolError(message):
            activeAgentItemID = nil
            phase = .failed(message)
        }
    }

    private func mergeAgentDelta(itemID: String, text: String) {
        guard !text.isEmpty, let activeWorkIndex else { return }

        if activeAgentItemID == itemID,
           let lastIndex = workSessions[activeWorkIndex].messages.indices.last,
           workSessions[activeWorkIndex].messages[lastIndex].role == .agent {
            workSessions[activeWorkIndex].messages[lastIndex].text.append(text)
        } else {
            workSessions[activeWorkIndex].messages.append(ConversationMessage(role: .agent, text: text))
            activeAgentItemID = itemID
        }
        workSessions[activeWorkIndex].updatedAt = .now
    }

    private func handleTimerCommand(
        _ command: ZileanMCPCommand,
        now: Date
    ) -> ZileanMCPCommandResponse {
        guard now.timeIntervalSince(command.createdAt) <= 10 else {
            return .failed(
                commandID: command.id,
                code: "expired_request",
                message: "타이머 시작 요청이 만료되었습니다. 다시 확인해 주세요."
            )
        }
        guard !command.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...1_440).contains(command.durationMinutes)
        else {
            return .failed(
                commandID: command.id,
                code: "invalid_arguments",
                message: "작업명과 집중 시간을 확인해 주세요."
            )
        }
        guard let workID = activeWorkID else {
            return .failed(
                commandID: command.id,
                code: "missing_active_work",
                message: "타이머를 연결할 활성 작업이 없습니다."
            )
        }
        if focusTimer?.status == .running {
            return .failed(
                commandID: command.id,
                code: "timer_already_running",
                message: "이미 실행 중인 집중 타이머가 있습니다."
            )
        }

        let session = FocusTimerSession(
            workID: workID,
            taskTitle: command.taskTitle,
            durationMinutes: command.durationMinutes,
            startedAt: now
        )
        focusTimer = session
        if let activeWorkIndex {
            workSessions[activeWorkIndex].title = command.taskTitle
            workSessions[activeWorkIndex].updatedAt = now
            workSessions[activeWorkIndex].focusTimer = session
        }
        return .started(command: command, session: session)
    }

    private func updateFocusTimer(_ timer: FocusTimerSession) {
        guard let workIndex = workSessions.firstIndex(where: { $0.id == timer.workID }) else { return }
        workSessions[workIndex].focusTimer = timer
    }

    private var activeWorkIndex: Int? {
        guard let activeWorkID else { return nil }
        return workSessions.firstIndex { $0.id == activeWorkID }
    }

    private func title(from message: String) -> String {
        let firstLine = message
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? message
        let maximumLength = 28

        guard firstLine.count > maximumLength else { return firstLine }
        return String(firstLine.prefix(maximumLength)) + "…"
    }
}
