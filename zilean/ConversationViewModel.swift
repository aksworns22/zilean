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
    @Published private(set) var messages: [ConversationMessage] = []
    @Published private(set) var selectedDirectory: URL?
    @Published var draft = ""

    private let client: CodexAppServerServing
    private var threadID: String?
    private var activeAgentItemID: String?

    var canCreateConversation: Bool {
        selectedDirectory != nil && client.isConnected && !phase.isBusy
    }

    var hasConversation: Bool {
        threadID != nil
    }

    var canSend: Bool {
        threadID != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !phase.isBusy
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
            if threadID == nil {
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
            threadID = try await client.startThread(in: selectedDirectory)
            messages.removeAll()
            activeAgentItemID = nil
            draft = ""
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func sendMessage() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let threadID, !text.isEmpty, !phase.isBusy else { return }

        draft = ""
        activeAgentItemID = nil
        messages.append(ConversationMessage(role: .user, text: text))
        phase = .responding

        do {
            _ = try await client.startTurn(threadID: threadID, text: text)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func shutdown() {
        client.stop()
        threadID = nil
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
            threadID = nil
            activeAgentItemID = nil
            phase = .failed(message)
        }
    }

    private func mergeAgentDelta(itemID: String, text: String) {
        guard !text.isEmpty else { return }

        if activeAgentItemID == itemID,
           let lastIndex = messages.indices.last,
           messages[lastIndex].role == .agent {
            messages[lastIndex].text.append(text)
        } else {
            messages.append(ConversationMessage(role: .agent, text: text))
            activeAgentItemID = itemID
        }
    }
}
