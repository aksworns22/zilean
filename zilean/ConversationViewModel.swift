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

enum RetrospectiveStatus: Equatable {
    case idle
    case waiting
    case requesting
    case prompted
    case answered
    case skipped
    case failed(String)
    case saveFailed(String)
}

@MainActor
final class ConversationViewModel: ObservableObject {
    @Published private(set) var phase: ConversationPhase = .disconnected
    @Published private(set) var workSessions: [WorkSession] = []
    @Published private(set) var activeWorkID: UUID?
    @Published private(set) var selectedDirectory: URL?
    @Published private(set) var focusTimer: FocusTimerSession?
    @Published private(set) var focusTimerPresentation: FocusTimerPresentation?
    @Published private(set) var retrospectiveStatus: RetrospectiveStatus = .idle
    @Published var draft = ""

    private let client: CodexAppServerServing
    private let harnessPreparer: CodexHarnessPreparing
    private let timerCommandStore: ZileanMCPCommandStore
    private let workLogStore: WorkLogStore
    private var activeAgentItemID: String?
    private var timerMonitorTask: Task<Void, Never>?
    private var focusTimerPresentationRefreshTimer: Timer?
    private var pendingTimerResponses: [UUID: ZileanMCPCommandResponse] = [:]
    private var pendingRetrospectiveTimer: FocusTimerSession?
    private var pendingRetrospectiveAnswer: String?
    private var activeTurn: ActiveTurn?

    private enum ActiveTurn {
        case user
        case retrospective(timerID: UUID)
    }

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

    var canRetryRetrospective: Bool {
        guard pendingRetrospectiveTimer != nil, client.isConnected, !phase.isBusy else {
            return false
        }
        switch retrospectiveStatus {
        case .failed, .saveFailed:
            return true
        default:
            return false
        }
    }

    var retrospectiveError: String? {
        switch retrospectiveStatus {
        case let .failed(message), let .saveFailed(message):
            message
        default:
            nil
        }
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
        ),
        workLogStore: WorkLogStore = WorkLogStore()
    ) {
        self.client = client
        self.harnessPreparer = harnessPreparer
        self.timerCommandStore = timerCommandStore
        self.workLogStore = workLogStore
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
            await requestRetrospectiveIfPossible()
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

        skipPendingRetrospective()
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

        handleUserInputDuringRetrospective(text)
        let threadID = workSessions[activeWorkIndex].threadID

        draft = ""
        activeAgentItemID = nil
        if workSessions[activeWorkIndex].messages.isEmpty {
            workSessions[activeWorkIndex].title = title(from: text)
        }
        workSessions[activeWorkIndex].messages.append(ConversationMessage(role: .user, text: text))
        workSessions[activeWorkIndex].updatedAt = .now
        phase = .responding
        activeTurn = .user

        do {
            _ = try await client.startTurn(threadID: threadID, text: text)
        } catch {
            activeTurn = nil
            phase = .failed(error.localizedDescription)
        }
    }

    func selectWork(id: UUID) {
        guard !phase.isBusy, let session = workSessions.first(where: { $0.id == id }) else { return }

        if id != activeWorkID {
            skipPendingRetrospective()
        }
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
        stopFocusTimerPresentationMonitoring()
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

    func completeFocusTimer(at date: Date = .now) async {
        guard var timer = focusTimer, timer.status == .running else { return }
        timer.status = .completed
        timer.completedAt = date
        focusTimer = timer
        updateFocusTimer(timer)
        refreshFocusTimerPresentation(at: date)
        pendingRetrospectiveTimer = timer
        retrospectiveStatus = .waiting
        await requestRetrospectiveIfPossible()
    }

    func refreshFocusTimerPresentation(at date: Date = .now) {
        focusTimerPresentation = FocusTimerPresentation.make(timer: focusTimer, now: date)

        if focusTimer?.status == .running {
            startFocusTimerPresentationMonitoring()
        } else {
            stopFocusTimerPresentationMonitoring()
        }
    }

    func retryRetrospective() async {
        guard pendingRetrospectiveTimer != nil else { return }

        if case .saveFailed = retrospectiveStatus,
           let answer = pendingRetrospectiveAnswer,
           let timer = pendingRetrospectiveTimer {
            saveRetrospectiveAnswer(answer, for: timer)
            return
        }
        guard case .failed = retrospectiveStatus else { return }

        retrospectiveStatus = .waiting
        await requestRetrospectiveIfPossible()
    }

    @discardableResult
    func startFocusTimer(
        taskTitle: String,
        durationMinutes: Int,
        at date: Date = .now
    ) -> ZileanMCPCommandResponse {
        let command = ZileanMCPCommand(
            taskTitle: taskTitle,
            durationMinutes: durationMinutes,
            createdAt: date
        )
        return startFocusTimer(command, now: date)
    }

    func handle(_ event: AppServerEvent) {
        switch event {
        case let .agentMessageDelta(itemID, text):
            mergeAgentDelta(itemID: itemID, text: text)

        case let .turnCompleted(status, errorMessage):
            let completedTurn = activeTurn
            activeTurn = nil
            activeAgentItemID = nil
            switch status {
            case .completed:
                phase = .completed
            case .interrupted:
                phase = .failed("Codex 응답이 중단되었습니다. 메시지를 다시 보내 주세요.")
            case .failed:
                phase = .failed(errorMessage ?? "Codex가 응답을 완료하지 못했습니다. 다시 시도해 주세요.")
            }

            switch completedTurn {
            case let .retrospective(timerID):
                guard pendingRetrospectiveTimer?.id == timerID else { return }
                if status == .completed {
                    retrospectiveStatus = .prompted
                } else {
                    failRetrospective(
                        errorMessage ?? "회고를 시작하지 못했습니다. 다시 시도해 주세요."
                    )
                }
            case .user:
                if status == .completed {
                    Task { @MainActor [weak self] in
                        await self?.requestRetrospectiveIfPossible()
                    }
                } else if pendingRetrospectiveTimer != nil {
                    failRetrospective(
                        "기존 대화 응답이 끝나지 않아 회고를 시작하지 못했습니다. 다시 시도해 주세요."
                    )
                }
            case .none:
                break
            }

        case let .processExited(message), let .protocolError(message):
            let wasRetrospectiveTurn = activeTurn.map { turn in
                if case .retrospective = turn { return true }
                return false
            } ?? false
            activeTurn = nil
            activeAgentItemID = nil
            phase = .failed(message)
            if wasRetrospectiveTurn {
                retrospectiveStatus = .failed(message)
            }
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
        return startFocusTimer(command, now: now)
    }

    private func startFocusTimer(
        _ command: ZileanMCPCommand,
        now: Date
    ) -> ZileanMCPCommandResponse {
        let taskTitle = command.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskTitle.isEmpty,
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
            taskTitle: taskTitle,
            durationMinutes: command.durationMinutes,
            startedAt: now
        )
        pendingRetrospectiveTimer = nil
        pendingRetrospectiveAnswer = nil
        retrospectiveStatus = .idle
        focusTimer = session
        refreshFocusTimerPresentation(at: now)
        if let activeWorkIndex {
            workSessions[activeWorkIndex].title = taskTitle
            workSessions[activeWorkIndex].updatedAt = now
            workSessions[activeWorkIndex].focusTimer = session
        }
        return .started(command: command, session: session)
    }

    private func updateFocusTimer(_ timer: FocusTimerSession) {
        guard let workIndex = workSessions.firstIndex(where: { $0.id == timer.workID }) else { return }
        workSessions[workIndex].focusTimer = timer
    }

    private func startFocusTimerPresentationMonitoring() {
        guard focusTimerPresentationRefreshTimer == nil else { return }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshFocusTimerPresentation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        focusTimerPresentationRefreshTimer = timer
    }

    private func stopFocusTimerPresentationMonitoring() {
        focusTimerPresentationRefreshTimer?.invalidate()
        focusTimerPresentationRefreshTimer = nil
    }

    private func requestRetrospectiveIfPossible() async {
        guard let timer = pendingRetrospectiveTimer,
              timer.status == .completed
        else { return }

        switch retrospectiveStatus {
        case .waiting, .failed:
            break
        case .idle, .requesting, .prompted, .answered, .skipped, .saveFailed:
            return
        }

        guard !phase.isBusy else { return }
        guard client.isConnected else {
            failRetrospective("Codex와 연결되어 있지 않습니다. 회고를 재시도해 주세요.")
            return
        }
        guard let workIndex = workSessions.firstIndex(where: { $0.id == timer.workID }) else {
            failRetrospective("회고를 연결할 작업 대화를 찾을 수 없습니다.")
            return
        }

        let work = workSessions[workIndex]
        activeWorkID = work.id
        selectedDirectory = work.directory
        activeAgentItemID = nil
        retrospectiveStatus = .requesting
        phase = .responding
        activeTurn = .retrospective(timerID: timer.id)

        do {
            _ = try await client.startTurn(
                threadID: work.threadID,
                text: retrospectivePrompt(for: timer)
            )
        } catch {
            activeTurn = nil
            failRetrospective(error.localizedDescription)
        }
    }

    private func retrospectivePrompt(for timer: FocusTimerSession) -> String {
        let completedAt = timer.completedAt ?? .now
        let elapsedSeconds = max(0, Int(timer.elapsed(at: completedAt)))
        let completedAtText = ISO8601DateFormatter().string(from: completedAt)

        return """
        [Zilean 내부 이벤트: 집중 타이머 완료]
        사용자가 아래 작업의 집중 타이머를 완료했다.
        - 작업명: \(timer.taskTitle)
        - 계획한 집중 시간: \(timer.durationMinutes)분
        - 실제 경과 시간: \(elapsedSeconds)초
        - 완료 시각: \(completedAtText)

        이 이벤트를 기술적인 형식으로 설명하지 말고, 기존 작업 대화의 맥락을 이어서 한국어로 짧고 부담 없는 회고와 다음 행동을 한 번 유도해라. 사용자가 이미 회고 내용을 말한 맥락이면 같은 질문을 반복하지 말고, 회고를 건너뛰거나 다른 요청을 하면 강요하지 마라.
        """
    }

    private func handleUserInputDuringRetrospective(_ answer: String) {
        guard pendingRetrospectiveTimer != nil else { return }

        switch retrospectiveStatus {
        case .prompted:
            if let timer = pendingRetrospectiveTimer {
                saveRetrospectiveAnswer(answer, for: timer)
            }
        case .waiting, .failed:
            retrospectiveStatus = .skipped
            pendingRetrospectiveTimer = nil
            pendingRetrospectiveAnswer = nil
        case .idle, .requesting, .answered, .skipped, .saveFailed:
            break
        }
    }

    private func saveRetrospectiveAnswer(_ answer: String, for timer: FocusTimerSession) {
        guard let completedAt = timer.completedAt,
              let work = workSessions.first(where: { $0.id == timer.workID })
        else {
            retrospectiveStatus = .saveFailed("작업 기록을 저장할 작업 정보를 찾지 못했습니다.")
            pendingRetrospectiveAnswer = answer
            return
        }

        do {
            _ = try workLogStore.save(
                WorkLogEntry(
                    taskTitle: timer.taskTitle,
                    startedAt: timer.startedAt,
                    completedAt: completedAt,
                    retrospective: answer
                ),
                in: work.directory
            )
            retrospectiveStatus = .answered
            pendingRetrospectiveTimer = nil
            pendingRetrospectiveAnswer = nil
        } catch {
            retrospectiveStatus = .saveFailed(
                "작업 기록을 저장하지 못했습니다: \(error.localizedDescription)"
            )
            pendingRetrospectiveAnswer = answer
        }
    }

    private func skipPendingRetrospective() {
        guard pendingRetrospectiveTimer != nil else { return }

        switch retrospectiveStatus {
        case .waiting, .failed, .prompted, .saveFailed:
            retrospectiveStatus = .skipped
            pendingRetrospectiveTimer = nil
            pendingRetrospectiveAnswer = nil
        case .idle, .requesting, .answered, .skipped, .saveFailed:
            break
        }
    }

    private func failRetrospective(_ message: String) {
        retrospectiveStatus = .failed(message)
        phase = .failed(message)
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
