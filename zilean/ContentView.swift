//
//  ContentView.swift
//  zilean
//
//  Created by 장대한 on 8/20/26.
//

import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: ConversationViewModel
    @State private var selectedDestination: SidebarDestination = .newWork
    @State private var minimizedTimerID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(DesignPalette.sidebarBorder)
                .frame(width: 1)
            workspace
        }
        .frame(minWidth: 800, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .task {
            viewModel.startTimerMonitoring()
            await viewModel.connect()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            viewModel.shutdown()
        }
        .onReceive(NotificationCenter.default.publisher(for: .zileanShowFocusTimer)) { _ in
            minimizedTimerID = nil
        }
        .onDisappear {
            viewModel.shutdown()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand

            VStack(spacing: 4) {
                navigationButton(
                    title: "새 작업",
                    systemImage: "square.and.pencil",
                    destination: .newWork,
                    action: startNewWork
                )
                .disabled(viewModel.phase.isBusy)

                navigationButton(
                    title: "돌아보기",
                    systemImage: "clock.arrow.circlepath",
                    destination: .review
                ) {
                    selectedDestination = .review
                }
            }
            .padding(.horizontal, 12)

            recentWork

            Spacer(minLength: 20)
        }
        .frame(width: 224)
        .background(DesignPalette.sidebarBackground)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image("ZileanAvatar")
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Zilean")
                    .font(.subheadline.weight(.semibold))
                Text("the Chronokeeper")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 46)
        .padding(.bottom, 18)
    }

    private func navigationButton(
        title: String,
        systemImage: String,
        destination: SidebarDestination,
        action: @escaping () -> Void
    ) -> some View {
        let isSelected = selectedDestination == destination

        return Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? DesignPalette.sidebarActiveText : Color.secondary)
        .background(
            isSelected ? DesignPalette.sidebarSelection : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private var recentWork: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("최근 작업")
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)

            if viewModel.recentWorkSessions.isEmpty {
                Text("아직 최근 작업이 없어요")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(spacing: 2) {
                        ForEach(viewModel.recentWorkSessions.prefix(5)) { work in
                            Button {
                                open(work)
                            } label: {
                                WorkSessionSummary(
                                    work: work,
                                    now: context.date,
                                    showsDetails: false,
                                    isActive: isSelected(work),
                                    isTimerRunning: isTimerRunning(for: work)
                                )
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.phase.isBusy)
                            .background(
                                isSelected(work)
                                    ? DesignPalette.sidebarSelection
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 22)
    }

    @ViewBuilder
    private var workspace: some View {
        if let timer = viewModel.focusTimer, minimizedTimerID != timer.id {
            FocusTimerView(
                timer: timer,
                minimize: { minimizedTimerID = timer.id },
                primaryAction: {
                    if timer.status == .running {
                        viewModel.completeFocusTimer()
                    } else {
                        viewModel.dismissCompletedFocusTimer()
                        minimizedTimerID = nil
                    }
                }
            )
        } else {
            conversationWorkspace
        }
    }

    private var conversationWorkspace: some View {
        VStack(spacing: 0) {
            workspaceStatus

            Group {
                switch selectedDestination {
                case .review:
                    reviewPlaceholder
                case .newWork, .currentWork:
                    conversation
                }
            }

            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var workspaceStatus: some View {
        HStack {
            if let directory = viewModel.selectedDirectory {
                Button {
                    startNewWork(choosingDirectory: true)
                } label: {
                    Label(directory.lastPathComponent, systemImage: "folder")
                        .font(.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("다른 작업 폴더 선택")
            }

            Spacer()

            if let timer = viewModel.focusTimer {
                Button {
                    minimizedTimerID = nil
                } label: {
                    Label(
                        timer.status == .running ? "집중 타이머 보기" : "완료된 타이머 보기",
                        systemImage: "timer"
                    )
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignPalette.sidebarActiveText)
                .help("집중 타이머 화면 열기")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .frame(height: 52, alignment: .top)
    }

    @ViewBuilder
    private var reviewPlaceholder: some View {
        if viewModel.recentWorkSessions.isEmpty {
            VStack(spacing: 8) {
                Text("아직 돌아볼 작업이 없어요")
                    .font(.title2.weight(.semibold))
                Text("새 작업을 시작하면 이곳에서 다시 열 수 있어요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("돌아보기")
                                .font(.title2.weight(.semibold))
                            Text("이 앱을 사용하는 동안 시작한 작업을 다시 열 수 있어요.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 6)

                        ForEach(viewModel.recentWorkSessions) { work in
                            Button {
                                open(work)
                            } label: {
                                WorkSessionSummary(
                                    work: work,
                                    now: context.date,
                                    showsDetails: true
                                )
                                .padding(16)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.phase.isBusy)
                            .background(
                                Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            }
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private var conversation: some View {
        if viewModel.messages.isEmpty {
            VStack(spacing: 10) {
                Text("오늘은 어떤 작업을 시작할까요?")
                    .font(.title2.weight(.semibold))

                Text(emptyStateDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(viewModel.messages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                }
                .onChange(of: viewModel.messages) { _, messages in
                    guard let lastID = messages.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyStateDescription: String {
        if viewModel.hasConversation {
            "질리언에게 메시지를 보내 작업을 시작하세요."
        } else if viewModel.selectedDirectory == nil {
            "새 작업을 눌러 작업 폴더를 선택하세요."
        } else {
            "새 작업을 눌러 대화를 시작하세요."
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if let detail = viewModel.phase.detail {
                ErrorBanner(
                    message: detail,
                    showsRetry: viewModel.canRetryConnection,
                    retry: { Task { await viewModel.connect() } }
                )
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    startNewWork(choosingDirectory: true)
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(viewModel.phase.isBusy)
                .accessibilityLabel("작업 폴더 선택")
                .help("새 작업 폴더 선택")

                TextField("질리언에게 메시지 보내기", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.vertical, 7)
                    .disabled(
                        selectedDestination == .review
                            || !viewModel.hasConversation
                            || viewModel.phase.isBusy
                    )
                    .onSubmit(sendMessage)

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(DesignPalette.userBubble, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSendMessage)
                .opacity(canSendMessage ? 1 : 0.35)
                .accessibilityLabel("메시지 보내기")
                .help("메시지 보내기")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            }
        }
        .frame(maxWidth: 680)
        .padding(.horizontal, 32)
        .padding(.top, 10)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity)
    }

    @discardableResult
    private func chooseDirectory() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Codex 작업 폴더 선택"
        panel.prompt = "선택"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        viewModel.selectDirectory(url)
        return true
    }

    private func startNewWork() {
        startNewWork(choosingDirectory: viewModel.selectedDirectory == nil)
    }

    private func startNewWork(choosingDirectory: Bool) {
        selectedDestination = .newWork

        if choosingDirectory, !chooseDirectory() {
            return
        }

        guard viewModel.selectedDirectory != nil else { return }

        Task {
            await viewModel.createConversation()
            if viewModel.hasConversation {
                selectedDestination = .currentWork
            }
        }
    }

    private func sendMessage() {
        guard canSendMessage else { return }
        Task { await viewModel.sendMessage() }
    }

    private func open(_ work: WorkSession) {
        guard !viewModel.phase.isBusy else { return }
        viewModel.selectWork(id: work.id)
        selectedDestination = .currentWork
    }

    private func isSelected(_ work: WorkSession) -> Bool {
        selectedDestination == .currentWork && viewModel.activeWorkID == work.id
    }

    private func isTimerRunning(for work: WorkSession) -> Bool {
        viewModel.focusTimer?.workID == work.id && viewModel.focusTimer?.status == .running
    }

    private var canSendMessage: Bool {
        selectedDestination != .review && viewModel.canSend
    }

}

private enum SidebarDestination {
    case newWork
    case review
    case currentWork
}

private struct FocusTimerView: View {
    let timer: FocusTimerSession
    let minimize: () -> Void
    let primaryAction: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: minimize) {
                        Label("최소화", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.72))
                    .background(
                        Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    }
                    .help("대화 화면으로 돌아가기")
                }
                .padding(.top, 22)
                .padding(.horizontal, 22)

                Spacer(minLength: 24)

                VStack(spacing: 26) {
                    VStack(spacing: 10) {
                        Text(timer.status == .running ? "집중 모드 · \(timer.taskTitle)" : "집중 완료 · \(timer.taskTitle)")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.52))
                            .lineLimit(1)

                        Text(FocusTimerTimeFormatter.string(from: timer.elapsed(at: context.date)))
                            .font(.system(size: 92, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.94))
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .accessibilityLabel(
                                "경과 시간 \(FocusTimerTimeFormatter.string(from: timer.elapsed(at: context.date)))"
                            )

                        HStack(spacing: 10) {
                            Text("예상")
                            Text(
                                FocusTimerTimeFormatter.string(
                                    from: TimeInterval(timer.durationMinutes * 60)
                                )
                            )
                                .monospacedDigit()
                        }
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.42))
                    }

                    VStack(spacing: 13) {
                        ProgressView(value: timer.progress(at: context.date))
                            .progressViewStyle(.linear)
                            .tint(.white.opacity(0.72))
                            .accessibilityLabel("집중 시간 진행률")
                            .accessibilityValue(
                                "\(Int(timer.progress(at: context.date) * 100))퍼센트"
                            )

                        Text(timer.status == .running ? "집중 중" : "완료됨")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    .frame(maxWidth: 500)

                    Button(
                        timer.status == .running ? "완료" : "대화로 돌아가기",
                        action: primaryAction
                    )
                    .buttonStyle(.plain)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(DesignPalette.focusBackground)
                    .frame(width: 160, height: 54)
                    .background(
                        Color.white.opacity(0.96),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .help(timer.status == .running ? "현재 집중 작업 완료" : "대화 화면으로 돌아가기")
                }
                .padding(.horizontal, 44)

                Spacer(minLength: 76)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignPalette.focusBackground)
        }
    }
}

private struct ErrorBanner: View {
    let message: String
    let showsRetry: Bool
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if showsRetry {
                Button("연결 재시도", action: retry)
            }
        }
        .padding(10)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MessageRow: View {
    let message: ConversationMessage

    @ViewBuilder
    var body: some View {
        if message.role == .user {
            HStack(alignment: .top) {
                Spacer(minLength: 80)

                messageBubble
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image("ZileanAvatar")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("질리언")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DesignPalette.agentName)

                    messageBubble
                }

                Spacer(minLength: 80)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var messageBubble: some View {
        Group {
            if message.role == .agent {
                MarkdownMessageView(source: message.text)
            } else {
                Text(message.text)
                    .textSelection(.enabled)
            }
        }
            .foregroundStyle(textColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                bubbleColor,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: message.role == .agent ? 8 : 14,
                    bottomLeadingRadius: 14,
                    bottomTrailingRadius: 14,
                    topTrailingRadius: message.role == .user ? 8 : 14,
                    style: .continuous
                )
            )
    }

    private var bubbleColor: Color {
        message.role == .user ? DesignPalette.userBubble : DesignPalette.agentBubble
    }

    private var textColor: Color {
        message.role == .user ? .white : DesignPalette.agentText
    }
}

private enum DesignPalette {
    static let focusBackground = Color(
        red: 10.0 / 255.0,
        green: 48.0 / 255.0,
        blue: 54.0 / 255.0
    )
    static let sidebarBackground = Color(
        red: 241.0 / 255.0,
        green: 245.0 / 255.0,
        blue: 246.0 / 255.0
    )
    static let sidebarBorder = Color.black.opacity(0.06)
    static let sidebarSelection = Color(
        red: 226.0 / 255.0,
        green: 237.0 / 255.0,
        blue: 238.0 / 255.0
    )
    static let sidebarActiveText = Color(
        red: 14.0 / 255.0,
        green: 46.0 / 255.0,
        blue: 52.0 / 255.0
    )
    static let agentBubble = Color(
        red: 238.0 / 255.0,
        green: 243.0 / 255.0,
        blue: 244.0 / 255.0
    )
    static let agentText = Color(
        red: 18.0 / 255.0,
        green: 38.0 / 255.0,
        blue: 43.0 / 255.0
    )
    static let agentName = Color(
        red: 101.0 / 255.0,
        green: 127.0 / 255.0,
        blue: 132.0 / 255.0
    )
    static let userBubble = Color(
        red: 14.0 / 255.0,
        green: 46.0 / 255.0,
        blue: 52.0 / 255.0
    )
}

private struct WorkSessionSummary: View {
    let work: WorkSession
    let now: Date
    let showsDetails: Bool
    var isActive = false
    var isTimerRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: showsDetails ? 7 : 3) {
            Text(work.title)
                .font(.callout.weight(.medium))
                .foregroundStyle(isActive ? DesignPalette.sidebarActiveText : Color.primary)
                .lineLimit(1)

            if showsDetails {
                HStack(spacing: 6) {
                    Label(work.directory.lastPathComponent, systemImage: "folder")
                    Text("·")
                    Text("메시지 \(work.messages.count)개")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            if isTimerRunning {
                Label("집중 중", systemImage: "timer")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(DesignPalette.sidebarActiveText)
            } else {
                Text(elapsedDescription(since: work.startedAt, now: now))
                    .font(.caption2)
                    .foregroundStyle(isActive ? DesignPalette.sidebarActiveText : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func elapsedDescription(since startDate: Date, now: Date) -> String {
    let elapsedMinutes = max(0, Int(now.timeIntervalSince(startDate) / 60))

    if elapsedMinutes == 0 {
        return "방금 시작"
    }
    if elapsedMinutes < 60 {
        return "\(elapsedMinutes)분 진행"
    }

    let hours = elapsedMinutes / 60
    let minutes = elapsedMinutes % 60
    return minutes == 0 ? "\(hours)시간 진행" : "\(hours)시간 \(minutes)분 진행"
}

#Preview {
    ContentView(viewModel: ConversationViewModel())
}
