import Foundation

enum FeedbackPeriod: String, CaseIterable, Identifiable {
    case today
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "오늘"
        case .all: "전체"
        }
    }

    func dateInterval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        switch self {
        case .today:
            return calendar.dateInterval(of: .day, for: date)!
        case .all:
            return DateInterval(start: .distantPast, end: .distantFuture)
        }
    }
}

struct FeedbackWorkItem: Identifiable, Equatable {
    let record: FeedbackRecord
    let actualDuration: TimeInterval

    var id: String { record.id }
    var title: String { record.taskTitle }
    var expectedDuration: TimeInterval? { record.plannedDuration }
    var difference: TimeInterval? { expectedDuration.map { actualDuration - $0 } }
}

struct FeedbackRecord: Identifiable, Equatable {
    let id: String
    let taskTitle: String
    let plannedDuration: TimeInterval?
    let startedAt: Date
    let completedAt: Date
    let actualDuration: TimeInterval

    init(
        id: String,
        taskTitle: String,
        plannedDuration: TimeInterval?,
        startedAt: Date,
        completedAt: Date,
        actualDuration: TimeInterval
    ) {
        self.id = id
        self.taskTitle = taskTitle
        self.plannedDuration = plannedDuration
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.actualDuration = actualDuration
    }

    init?(work: WorkSession) {
        guard let timer = work.focusTimer,
              timer.status == .completed,
              let completedAt = timer.completedAt
        else { return nil }

        self.init(
            id: "session-\(work.id.uuidString)",
            taskTitle: work.title,
            plannedDuration: TimeInterval(timer.durationMinutes * 60),
            startedAt: timer.startedAt,
            completedAt: completedAt,
            actualDuration: timer.elapsed(at: completedAt)
        )
    }

    var identity: String {
        "\(taskTitle)\u{1F}\(Int(startedAt.timeIntervalSince1970))\u{1F}\(Int(completedAt.timeIntervalSince1970))\u{1F}\(plannedDuration ?? -1)"
    }
}

struct FeedbackInsights: Equatable {
    let period: FeedbackPeriod
    let interval: DateInterval
    let items: [FeedbackWorkItem]

    init(
        records: [FeedbackRecord],
        period: FeedbackPeriod,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        self.period = period
        let selectedInterval = period.dateInterval(containing: now, calendar: calendar)
        interval = selectedInterval
        items = records.compactMap { record in
            guard selectedInterval.contains(record.completedAt) else { return nil }
            return FeedbackWorkItem(
                record: record,
                actualDuration: record.actualDuration
            )
        }
        .sorted { $0.record.completedAt > $1.record.completedAt }
    }

    var completedWorkCount: Int { items.count }

    var totalFocusDuration: TimeInterval {
        items.reduce(0) { $0 + $1.actualDuration }
    }

    /// The average closeness of each completed task's actual duration to its plan.
    /// A task that takes exactly its estimate scores 100%; scores are clamped at 0%.
    var estimateAccuracy: Int? {
        let itemsWithPlan = items.filter { ($0.expectedDuration ?? 0) > 0 }
        guard !itemsWithPlan.isEmpty else { return nil }
        let score = itemsWithPlan.reduce(0.0) { partial, item in
            let differenceRatio = abs(item.difference!) / item.expectedDuration!
            return partial + max(0, 1 - differenceRatio)
        } / Double(itemsWithPlan.count)
        return Int((score * 100).rounded())
    }

    var periodDescription: String {
        guard period != .all else { return "전체 기록" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.calendar = Calendar.current
        formatter.dateFormat = "M월 d일"

        let endDate = Calendar.current.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        if Calendar.current.isDate(interval.start, inSameDayAs: endDate) {
            return formatter.string(from: interval.start)
        }
        return "\(formatter.string(from: interval.start)) – \(formatter.string(from: endDate))"
    }

    var contextForFeedback: String {
        guard !items.isEmpty else {
            return "선택 기간에는 완료된 집중 작업 기록이 없습니다. 기록이 없다는 점을 먼저 알리고, 부담 없이 다음 집중 작업을 시작할 수 있는 방법을 안내해라."
        }

        let rows = items.map { item in
            let difference = item.difference.map(signedDurationDescription) ?? "계산할 수 없음"
            let planned = item.expectedDuration.map(feedbackDurationDescription) ?? "기록되지 않음"
            return "- \(item.title): 예상 \(planned), 실제 \(feedbackDurationDescription(item.actualDuration)), 차이 \(difference)"
        }.joined(separator: "\n")
        let accuracy = estimateAccuracy.map { "\($0)%" } ?? "계산할 수 없음"

        return """
        선택 기간: \(periodDescription)
        완료 작업 수: \(completedWorkCount)개
        총 집중 시간: \(feedbackDurationDescription(totalFocusDuration))
        예상 정확도: \(accuracy)
        작업별 기록:
        \(rows)
        """
    }
}

func signedDurationDescription(_ duration: TimeInterval) -> String {
    let roundedMinutes = Int(abs(duration) / 60)
    guard roundedMinutes > 0 else { return "0분" }
    return "\(duration > 0 ? "+" : "−")\(feedbackDurationDescription(abs(duration)))"
}

func feedbackDurationDescription(_ duration: TimeInterval) -> String {
    let elapsedMinutes = max(0, Int(duration / 60))
    if elapsedMinutes < 60 {
        return "\(elapsedMinutes)분"
    }

    let hours = elapsedMinutes / 60
    let minutes = elapsedMinutes % 60
    return minutes == 0 ? "\(hours)시간" : "\(hours)시간 \(minutes)분"
}
