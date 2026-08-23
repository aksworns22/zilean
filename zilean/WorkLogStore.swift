import Foundation

struct WorkLogEntry: Equatable {
    let taskTitle: String
    let plannedDurationMinutes: Int?
    let startedAt: Date
    let completedAt: Date
    let retrospective: String
    let conversation: [ConversationMessage]

    init(
        taskTitle: String,
        plannedDurationMinutes: Int? = nil,
        startedAt: Date,
        completedAt: Date,
        retrospective: String,
        conversation: [ConversationMessage] = []
    ) {
        self.taskTitle = taskTitle
        self.plannedDurationMinutes = plannedDurationMinutes
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.retrospective = retrospective
        self.conversation = conversation
    }
}

struct WorkLogStore {
    private let fileManager: FileManager
    private let calendar: Calendar

    init(fileManager: FileManager = .default, calendar: Calendar = .current) {
        self.fileManager = fileManager
        self.calendar = calendar
    }

    func save(_ entry: WorkLogEntry, in workDirectory: URL) throws -> URL {
        let directory = workDirectory
            .appendingPathComponent("work-records", isDirectory: true)
            .appendingPathComponent(dateDirectoryName(for: entry.completedAt), isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let destination = availableFileURL(
            in: directory,
            filename: safeFilename(from: entry.taskTitle)
        )
        try Data(markdown(for: entry).utf8).write(to: destination, options: .atomic)
        return destination
    }

    private func dateDirectoryName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func availableFileURL(in directory: URL, filename: String) -> URL {
        let stem = filename.isEmpty ? "work-log" : filename
        var suffix = 1
        var url = directory.appendingPathComponent("\(stem).md", isDirectory: false)

        while fileManager.fileExists(atPath: url.path) {
            suffix += 1
            url = directory.appendingPathComponent("\(stem)-\(suffix).md", isDirectory: false)
        }
        return url
    }

    private func safeFilename(from title: String) -> String {
        let reservedCharacters = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let replaced = title.unicodeScalars.map { scalar in
            reservedCharacters.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
                ? " "
                : String(scalar)
        }.joined()
        let joined = replaced
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))

        return String(joined.prefix(80))
    }

    private func markdown(for entry: WorkLogEntry) -> String {
        let completedAt = formattedTimestamp(entry.completedAt)
        let startedAt = formattedTimestamp(entry.startedAt)
        let elapsedSeconds = max(0, Int(entry.completedAt.timeIntervalSince(entry.startedAt)))
        let title = entry.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let plannedSeconds = entry.plannedDurationMinutes.map { max(0, $0 * 60) }
        let durationDifference = plannedSeconds.map { elapsedSeconds - $0 }
        let meaningfulMessages = entry.conversation.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let plannedMinutesYAML = entry.plannedDurationMinutes.map(String.init) ?? "null"
        let plannedSecondsYAML = plannedSeconds.map(String.init) ?? "null"
        let durationDifferenceYAML = durationDifference.map(String.init) ?? "null"
        let contextStatus = meaningfulMessages.isEmpty ? "unavailable" : "recorded"

        return """
        ---
        task_title: \(yamlString(title))
        planned_focus_minutes: \(plannedMinutesYAML)
        planned_focus_seconds: \(plannedSecondsYAML)
        started_at: \(startedAt)
        completed_at: \(completedAt)
        elapsed_seconds: \(elapsedSeconds)
        duration_difference_seconds: \(durationDifferenceYAML)
        conversation_context_status: \(contextStatus)
        conversation_context_message_count: \(meaningfulMessages.count)
        ---

        # \(title)

        ## 시간 기록

        - 계획한 집중 시간: \(plannedDurationDescription(entry.plannedDurationMinutes))
        - 시작: \(startedAt)
        - 완료: \(completedAt)
        - 실제 소요 시간: \(elapsedSeconds)초
        - 계획 대비 차이: \(durationDifferenceDescription(durationDifference))

        ## 대화 맥락

        \(conversationMarkdown(for: meaningfulMessages))

        ## 회고와 후속 작업

        \(entry.retrospective.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    private func plannedDurationDescription(_ minutes: Int?) -> String {
        guard let minutes else { return "기록되지 않음" }
        return "\(max(0, minutes))분"
    }

    private func durationDifferenceDescription(_ seconds: Int?) -> String {
        guard let seconds else { return "계산할 수 없음 (계획 시간이 기록되지 않음)" }
        if seconds == 0 { return "0초" }
        return "\(seconds > 0 ? "+" : "−")\(abs(seconds))초"
    }

    private func conversationMarkdown(for messages: [ConversationMessage]) -> String {
        guard !messages.isEmpty else {
            return "저장된 대화가 없습니다. 이 기록만으로는 대화 기반 맥락을 평가할 수 없습니다."
        }

        return messages.enumerated().map { index, message in
            let role: String
            switch message.role {
            case .user:
                role = "사용자"
            case .agent:
                role = "어시스턴트"
            }
            return """
            ### \(index + 1). \(role) · \(formattedTimestamp(message.createdAt))

            \(message.text.trimmingCharacters(in: .whitespacesAndNewlines))
            """
        }
        .joined(separator: "\n\n")
    }

    private func formattedTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func yamlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
