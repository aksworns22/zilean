import Foundation

struct WorkLogEntry: Equatable {
    let taskTitle: String
    let startedAt: Date
    let completedAt: Date
    let retrospective: String
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

        return """
        ---
        task_title: \(yamlString(title))
        started_at: \(startedAt)
        completed_at: \(completedAt)
        elapsed_seconds: \(elapsedSeconds)
        ---

        # \(title)

        ## 작업 기록

        - 시작: \(startedAt)
        - 완료: \(completedAt)
        - 실제 소요 시간: \(elapsedSeconds)초

        ## 회고와 후속 작업

        \(entry.retrospective.trimmingCharacters(in: .whitespacesAndNewlines))
        """
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
