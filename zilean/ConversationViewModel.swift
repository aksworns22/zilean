import Combine
import Foundation

nonisolated struct ConversationMessage: Identifiable, Codable, Equatable, Sendable {
    enum Role: String, Codable, Equatable, Sendable {
        case user
        case agent
    }

    let id: UUID
    let role: Role
    let createdAt: Date
    var text: String

    init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.createdAt = createdAt
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
    case answering
    case finalizing
    case answered
    case failed(String)
    case saveFailed(String)
}

@MainActor
final class ConversationViewModel: ObservableObject {
    @Published private(set) var phase: ConversationPhase = .disconnected
    @Published private(set) var workSessions: [WorkSession] = []
    @Published private(set) var activeWorkID: UUID?
    @Published private(set) var selectedDirectory: URL?
    @Published private(set) var directoryError: String?
    @Published private(set) var focusTimer: FocusTimerSession?
    @Published private(set) var focusTimerPresentation: FocusTimerPresentation?
    @Published private(set) var retrospectiveStatus: RetrospectiveStatus = .idle
    @Published var draft = ""
    @Published private(set) var feedbackMessages: [ConversationMessage] = []
    @Published var feedbackDraft = ""
    @Published private(set) var feedbackPeriod: FeedbackPeriod = .all

    private let client: CodexAppServerServing
    private let harnessPreparer: CodexHarnessPreparing
    private let timerCommandStore: ZileanMCPCommandStore
    private let workLogStore: any WorkLogStoring
    private let workDirectoryStore: WorkDirectoryStore
    private let retrospectiveDraftStore: RetrospectiveDraftStore
    private var savedDirectory: URL?
    private let promptTemplateLoader: any PromptTemplateLoading
    private var activeAgentItemID: String?
    private var timerMonitorTask: Task<Void, Never>?
    private var focusTimerPresentationRefreshTimer: Timer?
    private var pendingTimerResponses: [UUID: ZileanMCPCommandResponse] = [:]
    private var pendingRetrospectiveTimer: FocusTimerSession?
    private var pendingRetrospectiveID: UUID?
    private var pendingRetrospectiveSummary: String?
    private var retrospectiveStage: RetrospectiveDraftStage?
    private var retrospectiveThreadIsResumed = true
    private var summaryMessageStartIndex: Int?
    private var activeTurn: ActiveTurn?
    private var feedbackThreadID: String?
    private var activeFeedbackAgentItemID: String?
    private var storedFeedbackRecords: [FeedbackRecord] = []
    private var unreadableFeedbackRecordPaths: [String] = []
    private var savedWorkIDs: Set<UUID> = []

    private enum ActiveTurn {
        case user
        case retrospectivePrompt(timerID: UUID)
        case retrospectiveReply(timerID: UUID)
        case retrospectiveSummary(timerID: UUID)
        case feedback
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
        selectedDirectory != nil
            && client.isConnected
            && !phase.isBusy
            && !isRetrospectiveInProgress
    }

    var canCreateNewWork: Bool {
        !isRetrospectiveInProgress && !phase.isBusy
    }

    var hasConversation: Bool {
        activeWork != nil
    }

    var canSend: Bool {
        activeWork != nil
            && client.isConnected
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !phase.isBusy
            && (
                !isRetrospectiveInProgress
                    || (isActiveWorkRetrospective && retrospectiveStatus == .prompted)
            )
    }

    var canComposeFeedback: Bool {
        !feedbackInsights().items.isEmpty
            && client.isConnected
            && !phase.isBusy
    }

    var canSendFeedback: Bool {
        canComposeFeedback
            && !feedbackDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canRetryConnection: Bool {
        !client.isConnected && !phase.isBusy
    }

    var canRetryRetrospective: Bool {
        guard pendingRetrospectiveTimer != nil, !phase.isBusy else {
            return false
        }
        switch retrospectiveStatus {
        case .failed, .saveFailed:
            return true
        default:
            return false
        }
    }

    var isRetrospectiveInProgress: Bool {
        pendingRetrospectiveTimer != nil
    }

    var pendingRetrospectiveWorkID: UUID? {
        pendingRetrospectiveTimer?.workID
    }

    var isActiveWorkRetrospective: Bool {
        activeWorkID == pendingRetrospectiveWorkID && isRetrospectiveInProgress
    }

    var canFinishRetrospective: Bool {
        isActiveWorkRetrospective
            && retrospectiveStage == .ready
            && client.isConnected
            && !phase.isBusy
    }

    var retrospectiveError: String? {
        switch retrospectiveStatus {
        case let .failed(message), let .saveFailed(message):
            message
        default:
            nil
        }
    }

    func feedbackInsights(at now: Date = .now) -> FeedbackInsights {
        let currentRecords = workSessions
            .filter {
                $0.directory.standardizedFileURL == selectedDirectory?.standardizedFileURL
                    && !savedWorkIDs.contains($0.id)
                    && $0.id != pendingRetrospectiveWorkID
            }
            .compactMap(FeedbackRecord.init)
        let storedIdentities = Set(storedFeedbackRecords.map(\.identity))
        return FeedbackInsights(
            records: storedFeedbackRecords + currentRecords.filter {
                !storedIdentities.contains($0.identity)
            },
            period: feedbackPeriod,
            now: now
        )
    }

    convenience init() {
        let mcpConfiguration = ZileanMCPConfiguration()
        self.init(
            client: CodexAppServerClient(mcpConfiguration: mcpConfiguration),
            harnessPreparer: CodexHarnessPreparer(),
            timerCommandStore: ZileanMCPCommandStore(
                rootDirectory: mcpConfiguration.rootDirectory
            ),
            promptTemplateLoader: BundlePromptTemplateLoader()
        )
    }

    convenience init(client: CodexAppServerServing) {
        self.init(
            client: client,
            harnessPreparer: CodexHarnessPreparer(),
            timerCommandStore: ZileanMCPCommandStore(
                rootDirectory: ZileanMCPConfiguration().rootDirectory
            ),
            promptTemplateLoader: BundlePromptTemplateLoader()
        )
    }

    init(
        client: CodexAppServerServing,
        harnessPreparer: CodexHarnessPreparing,
        timerCommandStore: ZileanMCPCommandStore = ZileanMCPCommandStore(
            rootDirectory: ZileanMCPConfiguration().rootDirectory
        ),
        workLogStore: (any WorkLogStoring)? = nil,
        workDirectoryStore: WorkDirectoryStore = WorkDirectoryStore(),
        promptTemplateLoader: any PromptTemplateLoading = BundlePromptTemplateLoader(),
        retrospectiveDraftStore: RetrospectiveDraftStore? = nil
    ) {
        self.client = client
        self.harnessPreparer = harnessPreparer
        self.timerCommandStore = timerCommandStore
        self.workLogStore = workLogStore ?? WorkLogStore()
        self.workDirectoryStore = workDirectoryStore
        self.promptTemplateLoader = promptTemplateLoader
        self.retrospectiveDraftStore = retrospectiveDraftStore
            ?? RetrospectiveDraftStore(rootDirectory: timerCommandStore.rootDirectory)
        do {
            savedDirectory = try workDirectoryStore.savedDirectory()
            selectedDirectory = savedDirectory
            refreshFeedbackRecords()
        } catch {
            workDirectoryStore.clear()
            directoryError = error.localizedDescription
        }
        client.onEvent = { [weak self] event in
            self?.handle(event)
        }
        restoreRetrospectiveDraft()
    }

    func connect() async {
        if retrospectiveStage == .saving, let timer = pendingRetrospectiveTimer {
            saveRetrospective(for: timer)
            if isRetrospectiveInProgress {
                return
            }
        }

        phase = .connecting
        do {
            if !client.isConnected {
                try await client.connect()
            }
            try await resumeRetrospectiveThreadIfNeeded()
            if !isRetrospectiveInProgress {
                phase = activeWorkID == nil ? .ready : .idle
            }
        } catch {
            failRetrospectiveRestore(error.localizedDescription)
        }
    }

    @discardableResult
    func selectDirectory(_ directory: URL) -> Bool {
        let previousDirectory = selectedDirectory?.standardizedFileURL
        selectedDirectory = directory.standardizedFileURL
        do {
            savedDirectory = try workDirectoryStore.save(directory)
            selectedDirectory = savedDirectory
            directoryError = nil
            if previousDirectory != savedDirectory {
                resetFeedbackConversation()
            }
            refreshFeedbackRecords()
            return true
        } catch {
            directoryError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func useSavedDirectoryForNewWork() -> Bool {
        guard let savedDirectory else { return false }
        do {
            let previousDirectory = selectedDirectory?.standardizedFileURL
            selectedDirectory = try workDirectoryStore.validatedDirectory(savedDirectory)
            directoryError = nil
            if previousDirectory != selectedDirectory {
                resetFeedbackConversation()
            }
            refreshFeedbackRecords()
            return true
        } catch {
            self.savedDirectory = nil
            selectedDirectory = nil
            workDirectoryStore.clear()
            directoryError = error.localizedDescription
            return false
        }
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
        guard let selectedDirectory,
              client.isConnected,
              !isRetrospectiveInProgress
        else { return }

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
        let isRetrospectiveReply = isActiveWorkRetrospective && retrospectiveStage == .ready
        guard !isRetrospectiveInProgress || isRetrospectiveReply else { return }

        draft = ""
        activeAgentItemID = nil
        if workSessions[activeWorkIndex].messages.isEmpty {
            workSessions[activeWorkIndex].title = title(from: text)
        }
        workSessions[activeWorkIndex].messages.append(ConversationMessage(role: .user, text: text))
        workSessions[activeWorkIndex].updatedAt = .now
        if isRetrospectiveReply {
            retrospectiveStage = .responding
            retrospectiveStatus = .answering
            do {
                try persistRetrospectiveDraft(stage: .responding)
            } catch {
                workSessions[activeWorkIndex].messages.removeLast()
                retrospectiveStage = .ready
                retrospectiveStatus = .prompted
                draft = text
                failRetrospective("회고 초안을 저장하지 못했습니다: \(error.localizedDescription)")
                return
            }
        }
        phase = .responding
        activeTurn = isRetrospectiveReply
            ? pendingRetrospectiveTimer.map { .retrospectiveReply(timerID: $0.id) }
            : .user

        do {
            _ = try await client.startTurn(threadID: threadID, text: text)
        } catch {
            activeTurn = nil
            if isRetrospectiveReply {
                failRetrospective(error.localizedDescription)
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func selectFeedbackPeriod(_ period: FeedbackPeriod) {
        guard feedbackPeriod != period else { return }
        feedbackPeriod = period
        resetFeedbackConversation()
    }

    func sendFeedbackMessage() async {
        let question = feedbackDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshFeedbackRecords()
        let insights = feedbackInsights()
        guard !question.isEmpty,
              !phase.isBusy,
              client.isConnected,
              let selectedDirectory,
              !insights.items.isEmpty
        else { return }

        feedbackDraft = ""
        feedbackMessages.append(ConversationMessage(role: .user, text: question))
        activeFeedbackAgentItemID = nil
        phase = .responding
        activeTurn = .feedback

        do {
            let threadID: String
            if let feedbackThreadID {
                threadID = feedbackThreadID
            } else {
                try harnessPreparer.prepare(in: selectedDirectory)
                let newThreadID = try await client.startThread(in: selectedDirectory)
                feedbackThreadID = newThreadID
                threadID = newThreadID
            }
            _ = try await client.startTurn(
                threadID: threadID,
                text: try feedbackPrompt(
                    insights: insights,
                    question: question,
                    workDirectory: selectedDirectory
                )
            )
        } catch {
            activeTurn = nil
            phase = .failed(error.localizedDescription)
        }
    }

    func selectWork(id: UUID) {
        guard !phase.isBusy, let session = workSessions.first(where: { $0.id == id }) else { return }

        activeWorkID = session.id
        if selectedDirectory?.standardizedFileURL != session.directory.standardizedFileURL {
            selectedDirectory = session.directory
            resetFeedbackConversation()
            refreshFeedbackRecords()
        }
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
        pendingRetrospectiveID = timer.id
        pendingRetrospectiveSummary = nil
        retrospectiveStage = .starting
        retrospectiveThreadIsResumed = true
        retrospectiveStatus = .waiting
        do {
            try persistRetrospectiveDraft(stage: .starting)
        } catch {
            failRetrospective("회고 초안을 저장하지 못했습니다: \(error.localizedDescription)")
            return
        }
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

        if !client.isConnected || !retrospectiveThreadIsResumed {
            await connect()
            return
        }

        switch retrospectiveStage {
        case .starting:
            retrospectiveStatus = .waiting
            await requestRetrospectiveIfPossible()
        case .responding:
            await retryRetrospectiveReply()
        case .summarizing:
            await finishRetrospective()
        case .saving:
            if let timer = pendingRetrospectiveTimer {
                do {
                    try persistRetrospectiveDraft(
                        stage: .saving,
                        finalSummary: pendingRetrospectiveSummary
                    )
                    saveRetrospective(for: timer)
                } catch {
                    retrospectiveStatus = .saveFailed(
                        "최종 회고 초안을 저장하지 못했습니다: \(error.localizedDescription)"
                    )
                }
            }
        case .ready:
            do {
                try persistRetrospectiveDraft(stage: .ready)
                retrospectiveStatus = .prompted
                phase = .completed
            } catch {
                failRetrospective("회고 초안을 저장하지 못했습니다: \(error.localizedDescription)")
            }
        case .none:
            break
        }
    }

    func finishRetrospective() async {
        guard let timer = pendingRetrospectiveTimer,
              let workIndex = workSessions.firstIndex(where: { $0.id == timer.workID }),
              retrospectiveStage == .ready || retrospectiveStage == .summarizing,
              !phase.isBusy,
              client.isConnected,
              retrospectiveThreadIsResumed
        else { return }

        retrospectiveStage = .summarizing
        retrospectiveStatus = .finalizing
        phase = .responding
        activeAgentItemID = nil
        summaryMessageStartIndex = workSessions[workIndex].messages.count
        activeTurn = .retrospectiveSummary(timerID: timer.id)

        do {
            try persistRetrospectiveDraft(stage: .summarizing)
            _ = try await client.startTurn(
                threadID: workSessions[workIndex].threadID,
                text: try promptTemplateLoader.load(.retrospectiveFeedback)
            )
        } catch {
            activeTurn = nil
            removeIncompleteSummaryIfNeeded()
            failRetrospective(error.localizedDescription)
        }
    }

    func returnToPendingRetrospective() {
        guard let workID = pendingRetrospectiveWorkID else { return }
        selectWork(id: workID)
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
            if case .feedback = activeTurn {
                mergeFeedbackAgentDelta(itemID: itemID, text: text)
            } else {
                mergeAgentDelta(itemID: itemID, text: text)
            }

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
            case let .retrospectivePrompt(timerID):
                guard pendingRetrospectiveTimer?.id == timerID else { return }
                if status == .completed {
                    retrospectiveStage = .ready
                    retrospectiveStatus = .prompted
                    persistCompletedRetrospectiveTurn(stage: .ready)
                } else {
                    failRetrospective(
                        errorMessage ?? "회고를 시작하지 못했습니다. 다시 시도해 주세요."
                    )
                }
            case let .retrospectiveReply(timerID):
                guard pendingRetrospectiveTimer?.id == timerID else { return }
                if status == .completed {
                    retrospectiveStage = .ready
                    retrospectiveStatus = .prompted
                    persistCompletedRetrospectiveTurn(stage: .ready)
                } else {
                    failRetrospective(
                        errorMessage ?? "회고 답변을 완료하지 못했습니다. 다시 시도해 주세요."
                    )
                }
            case let .retrospectiveSummary(timerID):
                guard let timer = pendingRetrospectiveTimer, timer.id == timerID else { return }
                if status == .completed,
                   let summary = completedSummaryText() {
                    pendingRetrospectiveSummary = summary
                    retrospectiveStage = .saving
                    do {
                        try persistRetrospectiveDraft(stage: .saving, finalSummary: summary)
                        saveRetrospective(for: timer)
                    } catch {
                        retrospectiveStatus = .saveFailed(
                            "최종 회고 초안을 저장하지 못했습니다: \(error.localizedDescription)"
                        )
                        phase = .failed(error.localizedDescription)
                    }
                } else {
                    removeIncompleteSummaryIfNeeded()
                    failRetrospective(
                        errorMessage ?? "최종 회고를 생성하지 못했습니다. 다시 시도해 주세요."
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
            case .feedback:
                break
            case .none:
                break
            }

        case let .processExited(message), let .protocolError(message):
            let wasRetrospectiveTurn = activeTurn.map { turn in
                switch turn {
                case .retrospectivePrompt, .retrospectiveReply, .retrospectiveSummary:
                    true
                case .user, .feedback:
                    false
                }
            } ?? false
            activeTurn = nil
            activeAgentItemID = nil
            phase = .failed(message)
            if isRetrospectiveInProgress {
                retrospectiveThreadIsResumed = false
            }
            if wasRetrospectiveTurn || isRetrospectiveInProgress {
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

    private func mergeFeedbackAgentDelta(itemID: String, text: String) {
        guard !text.isEmpty else { return }

        if activeFeedbackAgentItemID == itemID,
           let lastIndex = feedbackMessages.indices.last,
           feedbackMessages[lastIndex].role == .agent {
            feedbackMessages[lastIndex].text.append(text)
        } else {
            feedbackMessages.append(ConversationMessage(role: .agent, text: text))
            activeFeedbackAgentItemID = itemID
        }
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
        if isRetrospectiveInProgress {
            return .failed(
                commandID: command.id,
                code: "retrospective_in_progress",
                message: "진행 중인 회고를 마친 뒤 새 타이머를 시작해 주세요."
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
        case .idle, .requesting, .prompted, .answering, .finalizing, .answered, .saveFailed:
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
        retrospectiveStage = .starting
        activeTurn = .retrospectivePrompt(timerID: timer.id)

        do {
            try persistRetrospectiveDraft(stage: .starting)
            _ = try await client.startTurn(
                threadID: work.threadID,
                text: try retrospectivePrompt(for: timer)
            )
        } catch {
            activeTurn = nil
            failRetrospective(error.localizedDescription)
        }
    }

    private func retrospectivePrompt(for timer: FocusTimerSession) throws -> String {
        let completedAt = timer.completedAt ?? .now
        let elapsedSeconds = max(0, Int(timer.elapsed(at: completedAt)))
        let completedAtText = ISO8601DateFormatter().string(from: completedAt)

        return try promptTemplateLoader.render(.retrospective, values: [
            "taskTitle": timer.taskTitle,
            "durationMinutes": String(timer.durationMinutes),
            "elapsedSeconds": String(elapsedSeconds),
            "completedAt": completedAtText,
        ])
    }

    private func feedbackPrompt(
        insights: FeedbackInsights,
        question: String,
        workDirectory: URL
    ) throws -> String {
        let formatter = ISO8601DateFormatter()
        let periodRange: String
        if insights.period == .all {
            periodRange = "저장된 전체 기록 (기간 경계 없음)"
        } else {
            periodRange = "\(formatter.string(from: insights.interval.start)) 포함 ~ \(formatter.string(from: insights.interval.end)) 제외"
        }
        return try promptTemplateLoader.render(.feedback, values: [
            "workDirectory": workDirectory.path,
            "periodRange": periodRange,
            "feedbackStatistics": insights.contextForFeedback,
            "unreadableRecordPaths": unreadableFeedbackRecordPaths.isEmpty
                ? "없음"
                : unreadableFeedbackRecordPaths.map { "- \($0)" }.joined(separator: "\n"),
            "question": question,
        ])
    }

    private func retryRetrospectiveReply() async {
        guard let timer = pendingRetrospectiveTimer,
              let work = workSessions.first(where: { $0.id == timer.workID }),
              let answer = work.messages.last(where: { $0.role == .user })?.text,
              !phase.isBusy,
              client.isConnected
        else {
            failRetrospective("회고 답변을 재시도할 수 없습니다. 연결을 확인해 주세요.")
            return
        }

        activeWorkID = work.id
        selectedDirectory = work.directory
        activeAgentItemID = nil
        retrospectiveStatus = .answering
        phase = .responding
        activeTurn = .retrospectiveReply(timerID: timer.id)

        do {
            try persistRetrospectiveDraft(stage: .responding)
            _ = try await client.startTurn(threadID: work.threadID, text: answer)
        } catch {
            activeTurn = nil
            failRetrospective(error.localizedDescription)
        }
    }

    private func saveRetrospective(for timer: FocusTimerSession) {
        guard let completedAt = timer.completedAt,
              let work = workSessions.first(where: { $0.id == timer.workID }),
              let summary = pendingRetrospectiveSummary?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ),
              !summary.isEmpty
        else {
            retrospectiveStatus = .saveFailed("저장할 최종 회고와 작업 정보를 찾지 못했습니다.")
            return
        }

        do {
            _ = try workLogStore.save(
                WorkLogEntry(
                    retrospectiveID: pendingRetrospectiveID,
                    taskTitle: timer.taskTitle,
                    plannedDurationMinutes: timer.durationMinutes,
                    startedAt: timer.startedAt,
                    completedAt: completedAt,
                    conversation: work.messages,
                    retrospectiveFeedback: summary
                ),
                in: work.directory
            )
            savedWorkIDs.insert(work.id)
            if work.directory.standardizedFileURL == selectedDirectory?.standardizedFileURL {
                refreshFeedbackRecords()
            }
            try retrospectiveDraftStore.clear()
            retrospectiveStatus = .answered
            pendingRetrospectiveTimer = nil
            pendingRetrospectiveID = nil
            pendingRetrospectiveSummary = nil
            retrospectiveStage = nil
            summaryMessageStartIndex = nil
        } catch {
            retrospectiveStatus = .saveFailed(
                "작업 기록을 저장하지 못했습니다: \(error.localizedDescription)"
            )
        }
    }

    private func failRetrospective(_ message: String) {
        retrospectiveStatus = .failed(message)
        phase = .failed(message)
    }

    private func failRetrospectiveRestore(_ message: String) {
        if isRetrospectiveInProgress {
            retrospectiveThreadIsResumed = false
            retrospectiveStatus = .failed("진행 중인 회고를 복원하지 못했습니다: \(message)")
        }
        phase = .failed(message)
    }

    private func restoreRetrospectiveDraft() {
        do {
            guard let draft = try retrospectiveDraftStore.load() else { return }
            let directory = URL(fileURLWithPath: draft.directoryPath).standardizedFileURL
            let session = WorkSession(
                id: draft.workID,
                threadID: draft.threadID,
                directory: directory,
                title: draft.title,
                startedAt: draft.workStartedAt,
                updatedAt: draft.workUpdatedAt,
                messages: draft.messages,
                focusTimer: draft.timer
            )
            workSessions.removeAll { $0.id == session.id }
            workSessions.append(session)
            activeWorkID = session.id
            selectedDirectory = directory
            focusTimer = draft.timer
            pendingRetrospectiveTimer = draft.timer
            pendingRetrospectiveID = draft.id
            pendingRetrospectiveSummary = draft.finalSummary
            retrospectiveStage = draft.stage
            retrospectiveThreadIsResumed = false
            retrospectiveStatus = .waiting
            refreshFocusTimerPresentation(at: draft.timer.completedAt ?? .now)
        } catch {
            retrospectiveStatus = .failed(
                "저장된 회고 초안을 읽지 못했습니다: \(error.localizedDescription)"
            )
        }
    }

    private func resumeRetrospectiveThreadIfNeeded() async throws {
        guard let timer = pendingRetrospectiveTimer,
              let stage = retrospectiveStage,
              !retrospectiveThreadIsResumed,
              let work = workSessions.first(where: { $0.id == timer.workID })
        else {
            if isRetrospectiveInProgress, retrospectiveThreadIsResumed {
                await continueRestoredRetrospectiveIfNeeded()
            }
            return
        }

        try harnessPreparer.prepare(in: work.directory)
        let resumedID = try await client.resumeThread(id: work.threadID)
        guard resumedID == work.threadID else {
            throw CodexAppServerError.invalidResponse("thread/resume")
        }
        retrospectiveThreadIsResumed = true
        retrospectiveStage = stage
        await continueRestoredRetrospectiveIfNeeded()
    }

    private func continueRestoredRetrospectiveIfNeeded() async {
        guard isRetrospectiveInProgress else { return }

        switch retrospectiveStage {
        case .starting:
            phase = .idle
            retrospectiveStatus = .waiting
            await requestRetrospectiveIfPossible()
        case .ready:
            phase = .idle
            retrospectiveStatus = .prompted
        case .responding:
            phase = .failed("AI 응답이 완료되지 않았습니다. 회고 재시도를 눌러 이어가세요.")
            retrospectiveStatus = .failed("AI 응답이 완료되지 않았습니다. 회고 재시도를 눌러 이어가세요.")
        case .summarizing:
            phase = .failed("최종 회고 생성이 완료되지 않았습니다. 다시 시도해 주세요.")
            retrospectiveStatus = .failed("최종 회고 생성이 완료되지 않았습니다. 다시 시도해 주세요.")
        case .saving:
            if let timer = pendingRetrospectiveTimer {
                saveRetrospective(for: timer)
            }
        case .none:
            break
        }
    }

    private func persistRetrospectiveDraft(
        stage: RetrospectiveDraftStage,
        finalSummary: String? = nil
    ) throws {
        guard let timer = pendingRetrospectiveTimer,
              let work = workSessions.first(where: { $0.id == timer.workID })
        else {
            throw CodexAppServerError.invalidResponse("retrospective/draft")
        }

        let retrospectiveID = pendingRetrospectiveID ?? timer.id
        pendingRetrospectiveID = retrospectiveID
        retrospectiveStage = stage
        if let finalSummary {
            pendingRetrospectiveSummary = finalSummary
        }
        try retrospectiveDraftStore.save(
            RetrospectiveDraft(
                id: retrospectiveID,
                workID: work.id,
                threadID: work.threadID,
                directoryPath: work.directory.path,
                title: work.title,
                workStartedAt: work.startedAt,
                workUpdatedAt: work.updatedAt,
                messages: work.messages,
                timer: timer,
                stage: stage,
                finalSummary: finalSummary ?? pendingRetrospectiveSummary
            )
        )
    }

    private func persistCompletedRetrospectiveTurn(stage: RetrospectiveDraftStage) {
        do {
            try persistRetrospectiveDraft(stage: stage)
            phase = .completed
        } catch {
            failRetrospective("회고 초안을 저장하지 못했습니다: \(error.localizedDescription)")
        }
    }

    private func completedSummaryText() -> String? {
        guard let workIndex = workSessions.firstIndex(where: { $0.id == pendingRetrospectiveWorkID }),
              let startIndex = summaryMessageStartIndex,
              startIndex < workSessions[workIndex].messages.count
        else { return nil }

        return workSessions[workIndex].messages[startIndex...]
            .filter { $0.role == .agent }
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removeIncompleteSummaryIfNeeded() {
        guard let workIndex = workSessions.firstIndex(where: { $0.id == pendingRetrospectiveWorkID }),
              let startIndex = summaryMessageStartIndex,
              startIndex <= workSessions[workIndex].messages.count
        else { return }
        workSessions[workIndex].messages.removeSubrange(startIndex...)
        summaryMessageStartIndex = nil
        activeAgentItemID = nil
    }

    private func refreshFeedbackRecords() {
        guard let selectedDirectory else {
            storedFeedbackRecords = []
            unreadableFeedbackRecordPaths = []
            return
        }
        let result = workLogStore.loadFeedbackRecords(in: selectedDirectory)
        storedFeedbackRecords = result.records
        unreadableFeedbackRecordPaths = result.unreadablePaths
    }

    private func resetFeedbackConversation() {
        feedbackDraft = ""
        feedbackMessages = []
        feedbackThreadID = nil
        activeFeedbackAgentItemID = nil
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
