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
    @StateObject private var menuBarTimerController: MenuBarTimerController
    @State private var selectedDestination: SidebarDestination = .newWork
    @State private var minimizedTimerID: UUID?
    @State private var isTimerSetupPresented = false
    @State private var timerSetupTaskTitle = ""
    @State private var timerSetupDurationMinutes = 25
    @State private var timerSetupError: String?

    init(viewModel: ConversationViewModel) {
        self.viewModel = viewModel
        _menuBarTimerController = StateObject(
            wrappedValue: MenuBarTimerController(viewModel: viewModel)
        )
    }

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
        .environmentObject(menuBarTimerController)
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
                    title: "피드백받기",
                    systemImage: "sparkles",
                    destination: .feedback
                ) {
                    closeTimerSetup()
                    selectedDestination = .feedback
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
                                    isActive: isSelected(work)
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
        if let presentation = viewModel.focusTimerPresentation,
           minimizedTimerID != presentation.timer.id {
            FocusTimerView(
                timer: presentation.timer,
                remainingText: presentation.remainingText,
                progress: presentation.progress,
                minimize: { minimizedTimerID = presentation.timer.id },
                primaryAction: {
                    if presentation.timer.status == .running {
                        Task {
                            await viewModel.completeFocusTimer()
                            minimizedTimerID = presentation.timer.id
                            selectedDestination = .currentWork
                        }
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

            switch selectedDestination {
            case .feedback:
                feedbackWorkspace
            case .newWork, .currentWork:
                VStack(spacing: 0) {
                    conversation
                    composer
                }
            }
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
    private var feedbackWorkspace: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                FeedbackInsightsView(
                    insights: viewModel.feedbackInsights(at: context.date),
                    selectedPeriod: viewModel.feedbackPeriod,
                    selectPeriod: viewModel.selectFeedbackPeriod
                )
            }

            Divider()
                .padding(.top, 8)

            feedbackConversation
            feedbackComposer
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

    @ViewBuilder
    private var feedbackConversation: some View {
        if viewModel.feedbackInsights().items.isEmpty {
            VStack(spacing: 8) {
                Text("피드백을 위한 기록을 쌓아보세요")
                    .font(.headline.weight(.semibold))
                Text("완료한 집중 작업이 생기면 이 기간의 기록을 바탕으로 질리언에게 피드백을 받을 수 있어요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.feedbackMessages.isEmpty {
            VStack(spacing: 8) {
                Text("이번 기록에서 무엇을 개선하면 좋을까요?")
                    .font(.headline.weight(.semibold))
                Text("예상 시간의 차이, 집중 패턴, 다음 주 계획을 질리언에게 물어보세요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(viewModel.feedbackMessages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                }
                .onChange(of: viewModel.feedbackMessages) { _, messages in
                    guard let lastID = messages.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var feedbackComposer: some View {
        VStack(spacing: 8) {
            if let error = viewModel.phase.detail {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 680, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.body.weight(.medium))
                    .foregroundStyle(DesignPalette.sidebarActiveText)
                    .frame(width: 30, height: 30)

                TextField(
                    "이번 기록에 대해 무엇이 궁금한가요?",
                    text: $viewModel.feedbackDraft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.vertical, 7)
                .disabled(!viewModel.canSendFeedback && viewModel.feedbackDraft.isEmpty)
                .onSubmit(sendFeedbackMessage)

                Button(action: sendFeedbackMessage) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(DesignPalette.userBubble, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSendFeedback)
                .opacity(viewModel.canSendFeedback ? 1 : 0.35)
                .accessibilityLabel("피드백 요청 보내기")
                .help("피드백 요청 보내기")
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
            if let detail = viewModel.phase.detail ?? viewModel.retrospectiveError {
                ErrorBanner(
                    message: detail,
                    showsRetry: viewModel.canRetryConnection || viewModel.canRetryRetrospective,
                    retryTitle: viewModel.canRetryRetrospective ? "회고 재시도" : "연결 재시도",
                    retry: {
                        Task {
                            if viewModel.canRetryRetrospective {
                                await viewModel.retryRetrospective()
                            } else {
                                await viewModel.connect()
                            }
                        }
                    }
                )
            }

            if isTimerSetupPresented {
                DirectTimerSetupCard(
                    taskTitle: $timerSetupTaskTitle,
                    durationMinutes: $timerSetupDurationMinutes,
                    hasActiveWork: viewModel.hasConversation,
                    errorMessage: timerSetupError,
                    close: closeTimerSetup,
                    start: startDirectTimer
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    toggleTimerSetup()
                } label: {
                    Image(systemName: isTimerSetupPresented ? "xmark" : "plus")
                        .font(.body.weight(.medium))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                        .background(
                            isTimerSetupPresented
                                ? DesignPalette.timerSetupButtonBackground
                                : Color.clear,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    isTimerSetupPresented
                        ? DesignPalette.timerSetupButtonForeground
                        : Color.secondary
                )
                .disabled(viewModel.phase.isBusy || selectedDestination == .feedback)
                .accessibilityLabel(
                    isTimerSetupPresented ? "타이머 설정 닫기" : "타이머 직접 설정"
                )
                .help(isTimerSetupPresented ? "타이머 설정 닫기" : "타이머 직접 설정")

                TextField("질리언에게 메시지 보내기", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.vertical, 7)
                    .disabled(
                        selectedDestination == .feedback
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
        closeTimerSetup()
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

    private func sendFeedbackMessage() {
        guard viewModel.canSendFeedback else { return }
        Task { await viewModel.sendFeedbackMessage() }
    }

    private func toggleTimerSetup() {
        guard !viewModel.phase.isBusy, selectedDestination != .feedback else { return }

        if isTimerSetupPresented {
            closeTimerSetup()
            return
        }

        if viewModel.focusTimer?.status == .running {
            minimizedTimerID = nil
            return
        }

        timerSetupTaskTitle = viewModel.activeWork?.title ?? ""
        timerSetupDurationMinutes = 25
        timerSetupError = viewModel.hasConversation
            ? nil
            : "타이머를 시작하려면 먼저 작업을 선택하세요."
        withAnimation(.easeOut(duration: 0.2)) {
            isTimerSetupPresented = true
        }
    }

    private func closeTimerSetup() {
        withAnimation(.easeOut(duration: 0.2)) {
            isTimerSetupPresented = false
        }
        timerSetupError = nil
    }

    private func startDirectTimer() {
        let response = viewModel.startFocusTimer(
            taskTitle: timerSetupTaskTitle,
            durationMinutes: timerSetupDurationMinutes
        )
        guard response.success else {
            timerSetupError = response.message
            return
        }

        timerSetupError = nil
        isTimerSetupPresented = false
        minimizedTimerID = nil
    }

    private func open(_ work: WorkSession) {
        guard !viewModel.phase.isBusy else { return }
        closeTimerSetup()
        viewModel.selectWork(id: work.id)
        selectedDestination = .currentWork
    }

    private func isSelected(_ work: WorkSession) -> Bool {
        selectedDestination == .currentWork && viewModel.activeWorkID == work.id
    }

    private var canSendMessage: Bool {
        selectedDestination != .feedback && viewModel.canSend
    }

}

private enum SidebarDestination {
    case newWork
    case feedback
    case currentWork
}

private struct DirectTimerSetupCard: View {
    @Binding var taskTitle: String
    @Binding var durationMinutes: Int

    let hasActiveWork: Bool
    let errorMessage: String?
    let close: () -> Void
    let start: () -> Void

    private let presets = [25, 45, 60, 120]
    private let durationStep = 5
    private let minimumDuration = 5
    private let maximumDuration = 1_440

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("타이머 직접 설정")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(DesignPalette.timerSetupText)

                Spacer()

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(DesignPalette.timerSetupMutedText)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("타이머 설정 닫기")
            }
            .padding(.bottom, 24)

            Text("작업 이름")
                .font(.callout.weight(.semibold))
                .foregroundStyle(DesignPalette.timerSetupMutedText)

            TextField("예 · DART 공시 작업", text: $taskTitle)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(DesignPalette.timerSetupText)
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                }
                .padding(.top, 10)

            Text("시간")
                .font(.callout.weight(.semibold))
                .foregroundStyle(DesignPalette.timerSetupMutedText)
                .padding(.top, 22)

            HStack(spacing: 0) {
                durationButton(
                    systemImage: "minus",
                    accessibilityLabel: "집중 시간 5분 줄이기",
                    isEnabled: durationMinutes > minimumDuration
                ) {
                    adjustDuration(by: -durationStep)
                }

                Spacer(minLength: 16)

                Text(formattedDuration)
                    .font(.system(size: 29, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(DesignPalette.timerSetupText)
                    .accessibilityLabel("집중 시간 \(formattedDuration)")

                Spacer(minLength: 16)

                durationButton(
                    systemImage: "plus",
                    accessibilityLabel: "집중 시간 5분 늘리기",
                    isEnabled: durationMinutes < maximumDuration
                ) {
                    adjustDuration(by: durationStep)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 68)
            .background(
                DesignPalette.timerSetupControlBackground,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .padding(.top, 10)

            HStack(spacing: 9) {
                ForEach(presets, id: \.self) { preset in
                    Button {
                        durationMinutes = preset
                    } label: {
                        Text(presetLabel(for: preset))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(
                                durationMinutes == preset
                                    ? Color.white
                                    : DesignPalette.timerSetupText
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                durationMinutes == preset
                                    ? DesignPalette.userBubble
                                    : Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        durationMinutes == preset
                                            ? Color.clear
                                            : Color.primary.opacity(0.14),
                                        lineWidth: 1
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("집중 시간 \(presetLabel(for: preset))")
                    .accessibilityAddTraits(durationMinutes == preset ? .isSelected : [])
                }
            }
            .padding(.top, 12)

            Divider()
                .padding(.vertical, 22)

            HStack(alignment: .center, spacing: 12) {
                Text(helperText)
                    .font(.callout)
                    .foregroundStyle(helperTextColor)
                    .lineLimit(2)

                Spacer(minLength: 8)

                Button("시작", action: start)
                    .buttonStyle(.plain)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 94, height: 52)
                    .background(
                        DesignPalette.userBubble,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .opacity(canStart ? 1 : 0.45)
                    .disabled(!canStart)
                    .accessibilityLabel("집중 타이머 시작")
            }
        }
        .padding(26)
        .frame(maxWidth: 462)
        .background(
            Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 22, y: 10)
        .accessibilityElement(children: .contain)
    }

    private var canStart: Bool {
        hasActiveWork
            && !taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (minimumDuration...maximumDuration).contains(durationMinutes)
            && durationMinutes.isMultiple(of: durationStep)
    }

    private var formattedDuration: String {
        let seconds = durationMinutes * 60
        return String(
            format: "%02d:%02d:%02d",
            seconds / 3_600,
            (seconds % 3_600) / 60,
            seconds % 60
        )
    }

    private var helperText: String {
        if let errorMessage {
            return errorMessage
        }
        if !hasActiveWork {
            return "타이머를 시작하려면 먼저 작업을 선택하세요."
        }
        return "5분 단위로 조절돼요"
    }

    private var helperTextColor: Color {
        errorMessage == nil && hasActiveWork ? .secondary : .red
    }

    private func adjustDuration(by amount: Int) {
        durationMinutes = min(
            maximumDuration,
            max(minimumDuration, durationMinutes + amount)
        )
    }

    private func presetLabel(for minutes: Int) -> String {
        switch minutes {
        case 60:
            return "1시간"
        case 120:
            return "2시간"
        default:
            return "\(minutes)분"
        }
    }

    private func durationButton(
        systemImage: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DesignPalette.timerSetupText)
                .frame(width: 46, height: 48)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct FocusTimerView: View {
    let timer: FocusTimerSession
    let remainingText: String
    let progress: Double
    let minimize: () -> Void
    let primaryAction: () -> Void

    var body: some View {
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

                        Text(remainingText)
                            .font(.system(size: 92, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.94))
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .accessibilityLabel(
                                "남은 시간 \(remainingText)"
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
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.white.opacity(0.72))
                            .accessibilityLabel("집중 시간 진행률")
                            .accessibilityValue(
                                "\(Int(progress * 100))퍼센트"
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

private struct ErrorBanner: View {
    let message: String
    let showsRetry: Bool
    let retryTitle: String
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
                Button(retryTitle, action: retry)
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

private struct FeedbackInsightsView: View {
    let insights: FeedbackInsights
    let selectedPeriod: FeedbackPeriod
    let selectPeriod: (FeedbackPeriod) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("피드백받기")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(DesignPalette.sidebarActiveText)
                        Text(insights.periodDescription)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(DesignPalette.timerSetupMutedText)
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        ForEach(FeedbackPeriod.allCases) { period in
                            Button {
                                selectPeriod(period)
                            } label: {
                                Text(period.title)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(
                                        selectedPeriod == period
                                            ? DesignPalette.sidebarActiveText
                                            : DesignPalette.timerSetupMutedText
                                    )
                                    .padding(.horizontal, 18)
                                    .frame(height: 38)
                                    .background(
                                        selectedPeriod == period ? Color.white : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                                    .shadow(
                                        color: selectedPeriod == period ? .black.opacity(0.07) : .clear,
                                        radius: 3,
                                        y: 1
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selectedPeriod == period ? .isSelected : [])
                            .accessibilityLabel("\(period.title) 기록 보기")
                        }
                    }
                    .padding(4)
                    .background(
                        DesignPalette.timerSetupControlBackground,
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
                }

                HStack(spacing: 14) {
                    FeedbackMetricCard(
                        title: "완료한 작업",
                        value: "\(insights.completedWorkCount)개",
                        accent: DesignPalette.sidebarActiveText
                    )
                    FeedbackMetricCard(
                        title: "집중 시간",
                        value: feedbackDurationDescription(insights.totalFocusDuration),
                        accent: DesignPalette.sidebarActiveText
                    )
                    FeedbackMetricCard(
                        title: "예상 정확도",
                        value: insights.estimateAccuracy.map { "\($0)%" } ?? "–",
                        accent: DesignPalette.feedbackAccent
                    )
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("작업 기록")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(DesignPalette.timerSetupMutedText)

                    if insights.items.isEmpty {
                        Text("이 기간에 완료한 집중 작업이 없어요.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .background(
                                Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                    } else {
                        ForEach(insights.items) { item in
                            FeedbackWorkRow(item: item)
                        }
                    }
                }
            }
            .frame(maxWidth: 1_050, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: 410)
    }
}

private struct FeedbackMetricCard: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(DesignPalette.timerSetupMutedText)
            Text(value)
                .font(.system(size: 31, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(
            DesignPalette.timerSetupControlBackground,
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

private struct FeedbackWorkRow: View {
    let item: FeedbackWorkItem

    var body: some View {
        HStack(spacing: 18) {
            Text(item.work.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(DesignPalette.sidebarActiveText)
                .lineLimit(1)

            Spacer(minLength: 20)

            HStack(spacing: 14) {
                labelledDuration("예상", value: feedbackDurationDescription(item.expectedDuration))
                labelledDuration("실제", value: feedbackDurationDescription(item.actualDuration))
                Text(signedDurationDescription(item.difference))
                    .font(.callout.weight(.bold))
                    .foregroundStyle(item.difference > 0 ? DesignPalette.feedbackAccent : DesignPalette.timerSetupMutedText)
                    .frame(minWidth: 48, alignment: .trailing)
            }
        }
        .padding(.horizontal, 22)
        .frame(minHeight: 58)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func labelledDuration(_ label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(DesignPalette.timerSetupMutedText)
            Text(value)
                .foregroundStyle(DesignPalette.sidebarActiveText)
                .monospacedDigit()
        }
        .font(.callout.weight(.medium))
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
    static let timerSetupText = Color(
        red: 14.0 / 255.0,
        green: 46.0 / 255.0,
        blue: 52.0 / 255.0
    )
    static let timerSetupMutedText = Color(
        red: 101.0 / 255.0,
        green: 127.0 / 255.0,
        blue: 132.0 / 255.0
    )
    static let timerSetupControlBackground = Color(
        red: 241.0 / 255.0,
        green: 245.0 / 255.0,
        blue: 246.0 / 255.0
    )
    static let timerSetupButtonBackground = Color(
        red: 226.0 / 255.0,
        green: 237.0 / 255.0,
        blue: 238.0 / 255.0
    )
    static let timerSetupButtonForeground = Color(
        red: 14.0 / 255.0,
        green: 46.0 / 255.0,
        blue: 52.0 / 255.0
    )
    static let feedbackAccent = Color(
        red: 202.0 / 255.0,
        green: 77.0 / 255.0,
        blue: 30.0 / 255.0
    )
}

private struct WorkSessionSummary: View {
    let work: WorkSession
    let now: Date
    let showsDetails: Bool
    var isActive = false

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

            if let timer = work.focusTimer {
                HStack(spacing: 5) {
                    Text("예상 \(durationDescription(TimeInterval(timer.durationMinutes * 60)))")
                    Text("·")
                    Text("실제 \(durationDescription(timer.elapsed(at: now)))")
                }
                .font(.caption2)
                .foregroundStyle(isActive ? DesignPalette.sidebarActiveText : Color.secondary)

            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func durationDescription(_ duration: TimeInterval) -> String {
    let elapsedMinutes = max(0, Int(duration / 60))
    if elapsedMinutes < 60 {
        return "\(elapsedMinutes)분"
    }

    let hours = elapsedMinutes / 60
    let minutes = elapsedMinutes % 60
    return minutes == 0 ? "\(hours)시간" : "\(hours)시간 \(minutes)분"
}

#Preview {
    ContentView(viewModel: ConversationViewModel())
}
