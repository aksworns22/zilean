import Foundation

nonisolated enum RetrospectiveDraftStage: String, Codable, Equatable, Sendable {
    case starting
    case ready
    case responding
    case summarizing
    case saving
}

nonisolated struct RetrospectiveDraft: Codable, Equatable, Sendable {
    let id: UUID
    let workID: UUID
    let threadID: String
    let directoryPath: String
    let title: String
    let workStartedAt: Date
    var workUpdatedAt: Date
    var messages: [ConversationMessage]
    var timer: FocusTimerSession
    var stage: RetrospectiveDraftStage
    var finalSummary: String?
}

nonisolated struct RetrospectiveDraftStore {
    private let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    var draftURL: URL {
        rootDirectory.appendingPathComponent("retrospective-draft.json", isDirectory: false)
    }

    var hasActiveDraft: Bool {
        fileManager.fileExists(atPath: draftURL.path)
    }

    func load() throws -> RetrospectiveDraft? {
        guard hasActiveDraft else { return nil }
        return try decoder().decode(RetrospectiveDraft.self, from: Data(contentsOf: draftURL))
    }

    func save(_ draft: RetrospectiveDraft) throws {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try encoder().encode(draft).write(to: draftURL, options: .atomic)
    }

    func clear() throws {
        guard hasActiveDraft else { return }
        try fileManager.removeItem(at: draftURL)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
