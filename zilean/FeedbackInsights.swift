import Foundation

enum FeedbackPeriod: String, CaseIterable, Identifiable {
    case today
    case thisWeek

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "오늘"
        case .thisWeek: "이번 주"
        }
    }

    func dateInterval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        switch self {
        case .today:
            return calendar.dateInterval(of: .day, for: date)!
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: date)!
        }
    }
}

struct FeedbackWorkItem: Identifiable, Equatable {
    let work: WorkSession
    let timer: FocusTimerSession
    let actualDuration: TimeInterval

    var id: UUID { work.id }
    var expectedDuration: TimeInterval { TimeInterval(timer.durationMinutes * 60) }
    var difference: TimeInterval { actualDuration - expectedDuration }
}

struct FeedbackInsights: Equatable {
    let period: FeedbackPeriod
    let interval: DateInterval
    let items: [FeedbackWorkItem]

    init(
        workSessions: [WorkSession],
        period: FeedbackPeriod,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        self.period = period
        let selectedInterval = period.dateInterval(containing: now, calendar: calendar)
        interval = selectedInterval
        items = workSessions.compactMap { work in
            guard let timer = work.focusTimer,
                  timer.status == .completed,
                  let completedAt = timer.completedAt,
                  selectedInterval.contains(completedAt)
            else { return nil }
            return FeedbackWorkItem(
                work: work,
                timer: timer,
                actualDuration: timer.elapsed(at: completedAt)
            )
        }
        .sorted { $0.timer.completedAt! > $1.timer.completedAt! }
    }

    var completedWorkCount: Int { items.count }

    var totalFocusDuration: TimeInterval {
        items.reduce(0) { $0 + $1.actualDuration }
    }

    /// The average closeness of each completed task's actual duration to its plan.
    /// A task that takes exactly its estimate scores 100%; scores are clamped at 0%.
    var estimateAccuracy: Int? {
        guard !items.isEmpty else { return nil }
        let score = items.reduce(0.0) { partial, item in
            let differenceRatio = abs(item.difference) / item.expectedDuration
            return partial + max(0, 1 - differenceRatio)
        } / Double(items.count)
        return Int((score * 100).rounded())
    }

    var periodDescription: String {
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
            let difference = signedDurationDescription(item.difference)
            return "- \(item.work.title): 예상 \(feedbackDurationDescription(item.expectedDuration)), 실제 \(feedbackDurationDescription(item.actualDuration)), 차이 \(difference)"
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
