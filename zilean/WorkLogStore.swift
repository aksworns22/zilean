import Foundation

struct WorkLogEntry: Equatable {
    let taskTitle: String
    let plannedDurationMinutes: Int?
    let startedAt: Date
    let completedAt: Date
    let conversation: [ConversationMessage]
    let retrospectiveFeedback: String?

    init(
        taskTitle: String,
        plannedDurationMinutes: Int? = nil,
        startedAt: Date,
        completedAt: Date,
        conversation: [ConversationMessage] = [],
        retrospectiveFeedback: String? = nil
    ) {
        self.taskTitle = taskTitle
        self.plannedDurationMinutes = plannedDurationMinutes
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.conversation = conversation
        self.retrospectiveFeedback = retrospectiveFeedback
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
        let recordsDirectory = workRecordsDirectory(in: workDirectory)
        let rawDirectory = recordsDirectory
            .appendingPathComponent("raw", isDirectory: true)
            .appendingPathComponent(dateDirectoryName(for: entry.completedAt), isDirectory: true)
        try fileManager.createDirectory(
            at: rawDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let rawDestination = availableFileURL(
            in: rawDirectory,
            filename: safeFilename(from: entry.taskTitle)
        )
        try write(rawMarkdown(for: entry), to: rawDestination)

        let wikiDirectory = recordsDirectory.appendingPathComponent("wiki", isDirectory: true)
        let taskDirectory = wikiDirectory
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent(dateDirectoryName(for: entry.completedAt), isDirectory: true)
        try fileManager.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try ensureSchema(in: wikiDirectory)

        let taskDestination = availableFileURL(
            in: taskDirectory,
            filename: safeFilename(from: entry.taskTitle)
        )
        try write(
            wikiTaskMarkdown(for: entry, rawURL: rawDestination, taskURL: taskDestination),
            to: taskDestination
        )
        try updateIndex(
            for: entry,
            taskURL: taskDestination,
            rawURL: rawDestination,
            in: wikiDirectory
        )
        try appendLog(
            for: entry,
            taskURL: taskDestination,
            rawURL: rawDestination,
            in: wikiDirectory
        )
        return rawDestination
    }

    private func workRecordsDirectory(in workDirectory: URL) -> URL {
        workDirectory.appendingPathComponent("work-records", isDirectory: true)
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

    private func rawMarkdown(for entry: WorkLogEntry) -> String {
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

        # \(title) · 원본 작업 기록

        ## 타이머 기록

        - 계획한 집중 시간: \(plannedDurationDescription(entry.plannedDurationMinutes))
        - 시작: \(startedAt)
        - 완료: \(completedAt)
        - 실제 소요 시간: \(elapsedSeconds)초
        - 계획 대비 차이: \(durationDifferenceDescription(durationDifference))

        ## AI와의 작업 대화 원문

        \(conversationMarkdown(for: meaningfulMessages))
        """
    }

    private func wikiTaskMarkdown(for entry: WorkLogEntry, rawURL: URL, taskURL: URL) -> String {
        let completedAt = formattedTimestamp(entry.completedAt)
        let startedAt = formattedTimestamp(entry.startedAt)
        let elapsedSeconds = max(0, Int(entry.completedAt.timeIntervalSince(entry.startedAt)))
        let title = entry.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPath = relativePath(from: taskURL.deletingLastPathComponent(), to: rawURL)

        return """
        ---
        source: \(yamlString(rawPath))
        completed_at: \(completedAt)
        ---

        # \(title) · \(dateDirectoryName(for: entry.completedAt))

        ## 시간 기록

        - 계획: \(plannedDurationDescription(entry.plannedDurationMinutes))
        - 실제: \(elapsedSeconds)초
        - 차이: \(durationDifferenceDescription(durationDifference(for: entry)))
        - 원본: [타이머와 AI 회고 대화](<\(rawPath)>)

        \(feedbackMarkdown(for: entry))
        """
    }

    private func feedbackMarkdown(for entry: WorkLogEntry) -> String {
        let feedback = entry.retrospectiveFeedback?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let feedback, !feedback.isEmpty else {
            return """
            ## 작업 완료 시간 예측의 정확성

            - 판단: AI 피드백을 저장하지 못해 평가할 수 없습니다.

            ## 작업 집중도의 밀도

            - 판단: AI 피드백을 저장하지 못해 평가할 수 없습니다.
            """
        }
        return feedback
    }

    private func ensureSchema(in wikiDirectory: URL) throws {
        let schemaURL = wikiDirectory.appendingPathComponent("SCHEMA.md", isDirectory: false)
        guard !fileManager.fileExists(atPath: schemaURL.path) else { return }

        try write(
            """
            # 작업 기록 위키 규칙

            - `../raw/`는 타이머 정보와 AI·사용자 대화 원문을 보관하는 변경하지 않는 근거 계층이다.
            - `tasks/`는 원본을 바탕으로 생성한 읽기 쉬운 작업 회고 페이지다. 시간 예측 정확성과 집중도를 분리해 정리한다.
            - `index.md`는 작업 페이지를 찾는 내용 중심 카탈로그다.
            - `log.md`는 작업 기록 생성 시점을 보존하는 append-only 이력이다.
            - 위키의 해석은 원본 작업 기록 링크를 근거로 해야 하며, 원본에 없는 사실을 단정하지 않는다.
            """,
            to: schemaURL
        )
    }

    private func updateIndex(
        for entry: WorkLogEntry,
        taskURL: URL,
        rawURL: URL,
        in wikiDirectory: URL
    ) throws {
        let indexURL = wikiDirectory.appendingPathComponent("index.md", isDirectory: false)
        let existing = try existingContents(of: indexURL)
        let taskPath = relativePath(from: wikiDirectory, to: taskURL)
        let rawPath = relativePath(from: wikiDirectory, to: rawURL)
        let lines = """
        - [\(markdownLinkText(entry.taskTitle))](<\(taskPath)>) — 완료 \(formattedTimestamp(entry.completedAt)) · 계획 \(plannedDurationDescription(entry.plannedDurationMinutes)) · 실제 \(actualDurationDescription(for: entry)) · 차이 \(durationDifferenceDescription(durationDifference(for: entry)))
          - 집중도: \(focusDensitySummary(for: entry))
          - 원본: [대화 원문](<\(rawPath)>)
        """
        let contents = existing ?? """
        # 작업 기록 인덱스

        작업별 AI 회고 페이지와 그 근거 원문을 빠르게 찾기 위한 목록입니다.

        ## 기록
        """

        try write("\(contents.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(lines)\n", to: indexURL)
    }

    private func appendLog(
        for entry: WorkLogEntry,
        taskURL: URL,
        rawURL: URL,
        in wikiDirectory: URL
    ) throws {
        let logURL = wikiDirectory.appendingPathComponent("log.md", isDirectory: false)
        let existing = try existingContents(of: logURL)
        let taskPath = relativePath(from: wikiDirectory, to: taskURL)
        let rawPath = relativePath(from: wikiDirectory, to: rawURL)
        let entryText = """
        ## [\(formattedTimestamp(entry.completedAt))] 작업 기록 생성 · \(entry.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines))

        - 작업 페이지: [\(markdownLinkText(entry.taskTitle))](<\(taskPath)>)
        - 원본: [타이머와 AI 회고 대화](<\(rawPath)>)
        - 계획: \(plannedDurationDescription(entry.plannedDurationMinutes))
        - 실제: \(actualDurationDescription(for: entry))
        - 계획 대비 차이: \(durationDifferenceDescription(durationDifference(for: entry)))
        """
        let contents = existing ?? """
        # 작업 기록 로그

        작업 기록 위키에 반영된 시점을 시간순으로 남기는 append-only 이력입니다.
        """

        try write("\(contents.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(entryText)\n", to: logURL)
    }

    private func existingContents(of url: URL) throws -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    private func relativePath(from directory: URL, to destination: URL) -> String {
        let sourceComponents = directory.standardizedFileURL.pathComponents
        let destinationComponents = destination.standardizedFileURL.pathComponents
        let commonCount = zip(sourceComponents, destinationComponents)
            .prefix { $0 == $1 }
            .count
        let upward = Array(repeating: "..", count: sourceComponents.count - commonCount)
        let downward = destinationComponents.dropFirst(commonCount)
        return (upward + Array(downward)).joined(separator: "/")
    }

    private func actualDurationDescription(for entry: WorkLogEntry) -> String {
        "\(max(0, Int(entry.completedAt.timeIntervalSince(entry.startedAt))))초"
    }

    private func durationDifference(for entry: WorkLogEntry) -> Int? {
        let elapsedSeconds = max(0, Int(entry.completedAt.timeIntervalSince(entry.startedAt)))
        return entry.plannedDurationMinutes.map { elapsedSeconds - max(0, $0 * 60) }
    }

    private func focusDensitySummary(for entry: WorkLogEntry) -> String {
        guard let feedback = entry.retrospectiveFeedback else {
            return "AI 피드백을 저장하지 못해 평가할 수 없음"
        }
        let lines = feedback.components(separatedBy: .newlines)
        guard let sectionIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "## 작업 집중도의 밀도"
        }) else {
            return "AI 회고 페이지 참조"
        }
        let sectionLines = lines.dropFirst(sectionIndex + 1)
        guard let summary = sectionLines.first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("- 판단:")
        }) else {
            return "AI 회고 페이지 참조"
        }
        return summary
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "- 판단:", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func markdownLinkText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
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
