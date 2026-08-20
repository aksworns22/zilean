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

    init(
        id: UUID = UUID(),
        threadID: String,
        directory: URL,
        title: String,
        startedAt: Date = .now,
        updatedAt: Date = .now,
        messages: [ConversationMessage] = []
    ) {
        self.id = id
        self.threadID = threadID
        self.directory = directory
        self.title = title
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.messages = messages
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

    var title: String {
        switch self {
        case .disconnected:
            "연결 안 됨"
        case .connecting:
            "Codex 연결 중"
        case .ready:
            "Codex 연결됨"
        case .creatingConversation:
            "새 대화 만드는 중"
        case .idle:
            "메시지 대기 중"
        case .responding:
            "응답 생성 중"
        case .completed:
            "완료"
        case .failed:
            "실패"
        }
    }

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
    @Published var draft = ""

    private let client: CodexAppServerServing
    private var activeAgentItemID: String?

    var activeWork: WorkSession? {
        guard let activeWorkID else { return nil }
        return workSessions.first { $0.id == activeWorkID }
    }

    var recentWorkSessions: [WorkSession] {
        workSessions.sorted { $0.updatedAt > $1.updatedAt }
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
        self.init(client: CodexAppServerClient())
    }

    init(client: CodexAppServerServing) {
        self.client = client
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

    func createConversation() async {
        guard let selectedDirectory, client.isConnected else { return }

        phase = .creatingConversation
        do {
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
        client.stop()
        activeAgentItemID = nil
        phase = .disconnected
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
