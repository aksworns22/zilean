//
//  zileanTests.swift
//  zileanTests
//
//  Created by 장대한 on 8/20/26.
//

import Foundation
import Testing
@testable import zilean

struct zileanTests {
    @Test func parsesMarkdownBlockStructure() {
        let source = """
        # 계획

        - **분석**
        - 구현

        1. 검증
        2. 배포

        > 결과를 확인합니다.

        ```swift
        let value = 1
        ```
        """

        #expect(MarkdownBlockParser.parse(source) == [
            .heading(level: 1, text: "계획"),
            .unorderedList(["**분석**", "구현"]),
            .orderedList(["검증", "배포"]),
            .quote("결과를 확인합니다."),
            .code(language: "swift", content: "let value = 1"),
        ])
    }

    @Test func preservesUnclosedCodeFenceDuringStreaming() {
        let source = """
        ```swift
        let value = 1
        """

        #expect(MarkdownBlockParser.parse(source) == [
            .code(language: "swift", content: "let value = 1"),
        ])
    }

    @Test func rendersInlineMarkdownAndLinks() {
        let attributed = MarkdownInlineParser.attributed(
            "**질리언**이 *강조*와 `코드`, [문서](https://example.com)를 표시합니다."
        )
        let intents = attributed.runs.compactMap(\.inlinePresentationIntent)

        #expect(String(attributed.characters) == "질리언이 강조와 코드, 문서를 표시합니다.")
        #expect(intents.contains { $0.contains(.stronglyEmphasized) })
        #expect(intents.contains { $0.contains(.emphasized) })
        #expect(intents.contains { $0.contains(.code) })
        #expect(attributed.runs.contains { $0.link?.absoluteString == "https://example.com" })
    }

    @Test func keepsMalformedInlineMarkdownContentVisible() {
        let attributed = MarkdownInlineParser.attributed("**아직 닫히지 않은 응답")

        #expect(String(attributed.characters).contains("아직 닫히지 않은 응답"))
    }

    @Test func decodesSplitAndMultipleJSONLMessages() throws {
        var decoder = JSONLMessageDecoder()

        let firstChunk = Data(#"{"id":1,"result":{"thread":{"id":"thr_1"}}}"#.utf8)
        let secondChunk = Data("\n{\"method\":\"turn/started\",\"params\":{}}\n".utf8)

        #expect(try decoder.append(firstChunk).isEmpty)
        let messages = try decoder.append(secondChunk)

        #expect(messages.count == 2)
        #expect(messages[0].id == 1)
        #expect(messages[0].value(at: "result", "thread", "id")?.stringValue == "thr_1")
        #expect(messages[1].method == "turn/started")
    }

    @Test func decodesTrailingMessageWhenStreamFinishes() throws {
        var decoder = JSONLMessageDecoder()
        let chunk = Data(#"{"method":"turn/completed","params":{}}"#.utf8)

        #expect(try decoder.append(chunk).isEmpty)
        let messages = try decoder.finish()

        #expect(messages.count == 1)
        #expect(messages[0].method == "turn/completed")
    }

    @Test func routesResponseOnlyToMatchingRequestID() throws {
        var router = JSONRPCResponseRouter()
        var deliveredIDs: [Int] = []

        router.register(id: 1) { result in
            if case let .success(message) = result, let id = message.id {
                deliveredIDs.append(id)
            }
        }
        router.register(id: 2) { result in
            if case let .success(message) = result, let id = message.id {
                deliveredIDs.append(id)
            }
        }

        let response = try AppServerMessage(data: Data(#"{"id":2,"result":{}}"#.utf8))
        let didRoute = router.route(response)
        #expect(didRoute)
        #expect(deliveredIDs == [2])
        #expect(router.pendingCount == 1)
    }

    @Test func preparesIsolatedMCPConfigurationArguments() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executableURL = URL(fileURLWithPath: "/Applications/Zilean Test.app/Contents/MacOS/zilean")
        let configuration = ZileanMCPConfiguration(
            executableURL: executableURL,
            rootDirectory: directory
        )

        let arguments = try configuration.prepareCodexArguments()

        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(arguments.prefix(2) == ["app-server", "--stdio"])
        #expect(arguments.contains("mcp_servers.zilean.command=\"/Applications/Zilean Test.app/Contents/MacOS/zilean\""))
        #expect(arguments.contains("mcp_servers.zilean.required=true"))
        #expect(arguments.contains("mcp_servers.zilean.env.LLVM_PROFILE_FILE=\"/dev/null\""))
        #expect(arguments.contains { $0.contains("--zilean-mcp-server") })
        #expect(arguments.contains { $0.contains(directory.path) })
    }

    @Test func MCPServerAdvertisesZileanTools() throws {
        let configurationDirectory = URL(fileURLWithPath: "/tmp/zilean-mcp-test")
        let protocolHandler = ZileanMCPProtocol(configurationDirectory: configurationDirectory)
        let request = try AppServerMessage(
            data: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8)
        )

        let response = try #require(protocolHandler.response(to: request))
        let message = AppServerMessage(payload: response)

        guard case let .array(tools) = try #require(message.value(at: "result", "tools")) else {
            Issue.record("MCP tools/list 결과가 배열이 아닙니다.")
            return
        }
        let toolNames = tools.compactMap { $0.objectValue?["name"]?.stringValue }

        #expect(toolNames == [
            ZileanMCPProtocol.statusToolName,
            ZileanMCPProtocol.startTimerToolName,
        ])
    }

    @Test func MCPStatusToolReturnsConfigurationDirectory() throws {
        let configurationDirectory = URL(fileURLWithPath: "/tmp/zilean-mcp-test")
        let protocolHandler = ZileanMCPProtocol(configurationDirectory: configurationDirectory)
        let request = try AppServerMessage(
            data: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"zilean_status","arguments":{}}}"#.utf8)
        )

        let response = try #require(protocolHandler.response(to: request))
        let message = AppServerMessage(payload: response)

        #expect(message.value(at: "result", "isError") == .bool(false))
        #expect(message.value(at: "result", "structuredContent", "connected") == .bool(true))
        #expect(
            message.value(at: "result", "structuredContent", "configurationDirectory")?.stringValue
                == configurationDirectory.path
        )
    }

    @Test func MCPStartTimerToolRejectsInvalidDuration() throws {
        let protocolHandler = ZileanMCPProtocol(
            configurationDirectory: URL(fileURLWithPath: "/tmp/zilean-mcp-test")
        )
        let request = try AppServerMessage(
            data: Data(
                #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"start_focus_timer","arguments":{"taskTitle":"DART 공시 작업","durationMinutes":0}}}"#.utf8
            )
        )

        let response = try #require(protocolHandler.response(to: request))
        let message = AppServerMessage(payload: response)

        #expect(message.value(at: "result", "isError") == .bool(true))
        #expect(
            message.value(at: "result", "structuredContent", "errorCode")?.stringValue
                == "invalid_duration"
        )
    }

    @Test func completedFocusTimerFreezesElapsedAndRemainingTime() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let completedAt = startedAt.addingTimeInterval(75)
        let timer = FocusTimerSession(
            workID: UUID(),
            taskTitle: "재무제표 정리",
            durationMinutes: 2,
            startedAt: startedAt,
            status: .completed,
            completedAt: completedAt
        )

        #expect(timer.elapsed(at: completedAt.addingTimeInterval(300)) == 75)
        #expect(timer.remaining(at: completedAt.addingTimeInterval(300)) == 45)
        #expect(timer.remainingText(at: completedAt.addingTimeInterval(300)) == "00:00:45")
        #expect(timer.progress(at: completedAt.addingTimeInterval(300)) == 0.625)
    }

    @Test func focusTimerRemainingTimeCountsDownFromTargetEnd() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let timer = FocusTimerSession(
            workID: UUID(),
            taskTitle: "재무제표 정리",
            durationMinutes: 2,
            startedAt: startedAt
        )

        #expect(timer.remaining(at: startedAt) == 120)
        #expect(timer.remaining(at: startedAt.addingTimeInterval(15)) == 105)
        #expect(timer.remainingText(at: startedAt.addingTimeInterval(15)) == "00:01:45")
    }

    @Test func focusTimerRemainingTimeClampsAtZero() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let timer = FocusTimerSession(
            workID: UUID(),
            taskTitle: "재무제표 정리",
            durationMinutes: 1,
            startedAt: startedAt
        )

        #expect(timer.remaining(at: startedAt.addingTimeInterval(61)) == 0)
        #expect(timer.remainingText(at: startedAt.addingTimeInterval(61)) == "00:00:00")
    }

    @Test func focusTimerPresentationKeepsMainAndMenuBarTimeInSync() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let runningTimer = FocusTimerSession(
            workID: UUID(),
            taskTitle: "재무제표 정리",
            durationMinutes: 25,
            startedAt: startedAt
        )
        let completedTimer = FocusTimerSession(
            workID: UUID(),
            taskTitle: "재무제표 정리",
            durationMinutes: 25,
            startedAt: startedAt,
            status: .completed,
            completedAt: startedAt.addingTimeInterval(75)
        )

        let runningPresentation = FocusTimerPresentation.make(
            timer: runningTimer,
            now: startedAt.addingTimeInterval(10)
        )
        let completedPresentation = FocusTimerPresentation.make(timer: completedTimer, now: startedAt)

        #expect(runningPresentation?.remainingText == "00:24:50")
        #expect(runningPresentation?.progress == 10.0 / 1_500.0)
        #expect(
            FocusTimerMenuBarState.make(presentation: runningPresentation)
                == .running(taskTitle: "재무제표 정리", remainingText: runningPresentation?.remainingText ?? "")
        )
        #expect(completedPresentation == nil)
        #expect(FocusTimerMenuBarState.make(presentation: completedPresentation) == .hidden)
        #expect(FocusTimerMenuBarState.make(presentation: nil) == .hidden)
    }

    @Test func savesWorkLogInDateDirectoryWithoutOverwritingExistingRecord() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 9 * 60 * 60))
        let completedAt = try #require(
            calendar.date(
                from: DateComponents(year: 2026, month: 8, day: 22, hour: 10, minute: 30)
            )
        )
        let entry = WorkLogEntry(
            taskTitle: "DART / 공시: 초안",
            startedAt: completedAt.addingTimeInterval(-75),
            completedAt: completedAt,
            retrospective: "핵심 숫자를 빠르게 확인했다. 다음에는 공시 요약을 팀에 공유한다."
        )
        let store = WorkLogStore(calendar: calendar)

        let firstURL = try store.save(entry, in: directory)
        let secondURL = try store.save(entry, in: directory)
        let markdown = try String(contentsOf: firstURL, encoding: .utf8)

        #expect(firstURL.path.hasSuffix("work-records/2026-08-22/DART-공시-초안.md"))
        #expect(secondURL.lastPathComponent == "DART-공시-초안-2.md")
        #expect(markdown.contains("task_title: \"DART / 공시: 초안\""))
        #expect(markdown.contains("elapsed_seconds: 75"))
        #expect(markdown.contains("## 회고와 후속 작업"))
        #expect(markdown.contains("다음에는 공시 요약을 팀에 공유한다."))
    }

    @Test @MainActor func startsFocusTimerFromPendingMCPCommand() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commandStore = ZileanMCPCommandStore(rootDirectory: directory)
        let client = StubAppServerClient()
        let viewModel = ConversationViewModel(
            client: client,
            harnessPreparer: StubHarnessPreparer(),
            timerCommandStore: commandStore
        )
        await viewModel.connect()
        viewModel.selectDirectory(directory)
        await viewModel.createConversation()
        #expect(viewModel.recentWorkSessions.isEmpty)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let command = ZileanMCPCommand(
            taskTitle: "DART 공시 작업",
            durationMinutes: 120,
            createdAt: startedAt
        )
        try commandStore.enqueue(command)

        viewModel.processPendingTimerCommands(now: startedAt)

        let timer = try #require(viewModel.focusTimer)
        let storedResponse = try commandStore.readResponse(for: command.id)
        let response = try #require(storedResponse)
        #expect(timer.taskTitle == "DART 공시 작업")
        #expect(timer.durationMinutes == 120)
        #expect(timer.startedAt == startedAt)
        #expect(viewModel.activeWork?.title == "DART 공시 작업")
        #expect(viewModel.recentWorkSessions.map(\.id) == [timer.workID])
        #expect(viewModel.recentWorkSessions.first?.focusTimer?.durationMinutes == 120)
        #expect(response.success)
        #expect(response.state == FocusTimerStatus.running.rawValue)
        #expect(try commandStore.pendingCommands().isEmpty)

        await viewModel.completeFocusTimer(at: startedAt.addingTimeInterval(6))
        #expect(viewModel.focusTimer?.status == .completed)
        #expect(viewModel.focusTimer?.elapsed(at: startedAt.addingTimeInterval(60)) == 6)
        #expect(viewModel.focusTimerPresentation == nil)
        #expect(viewModel.recentWorkSessions.first?.focusTimer?.status == .completed)
        #expect(viewModel.recentWorkSessions.first?.focusTimer?.elapsed(at: startedAt.addingTimeInterval(60)) == 6)
    }

    @Test @MainActor func requestsRetrospectiveWhenFocusTimerCompletes() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commandStore = ZileanMCPCommandStore(rootDirectory: directory)
        let client = StubAppServerClient()
        let viewModel = ConversationViewModel(
            client: client,
            harnessPreparer: StubHarnessPreparer(),
            timerCommandStore: commandStore
        )

        await viewModel.connect()
        viewModel.selectDirectory(directory)
        await viewModel.createConversation()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let command = ZileanMCPCommand(
            taskTitle: "회고 대상 작업",
            durationMinutes: 25,
            createdAt: startedAt
        )
        try commandStore.enqueue(command)
        viewModel.processPendingTimerCommands(now: startedAt)

        let completedAt = startedAt.addingTimeInterval(75)
        await viewModel.completeFocusTimer(at: completedAt)

        let prompt = try #require(client.startTurnTexts.last)
        #expect(viewModel.focusTimer?.status == .completed)
        #expect(viewModel.retrospectiveStatus == .requesting)
        #expect(prompt.contains("회고 대상 작업"))
        #expect(prompt.contains("계획한 집중 시간: 25분"))
        #expect(prompt.contains("실제 경과 시간: 75초"))

        client.onEvent?(.turnCompleted(status: .completed, errorMessage: nil))

        #expect(viewModel.retrospectiveStatus == .prompted)
    }

    @Test @MainActor func keepsRetrospectiveRetryableAfterTurnFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commandStore = ZileanMCPCommandStore(rootDirectory: directory)
        let client = StubAppServerClient()
        let viewModel = ConversationViewModel(
            client: client,
            harnessPreparer: StubHarnessPreparer(),
            timerCommandStore: commandStore
        )

        await viewModel.connect()
        viewModel.selectDirectory(directory)
        await viewModel.createConversation()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let command = ZileanMCPCommand(
            taskTitle: "재시도 작업",
            durationMinutes: 10,
            createdAt: startedAt
        )
        try commandStore.enqueue(command)
        viewModel.processPendingTimerCommands(now: startedAt)

        client.startTurnError = TestError.preparationFailed
        await viewModel.completeFocusTimer(at: startedAt.addingTimeInterval(10))

        #expect(viewModel.focusTimer?.status == .completed)
        #expect(viewModel.retrospectiveStatus == .failed(TestError.preparationFailed.localizedDescription))
        #expect(viewModel.canRetryRetrospective)

        client.startTurnError = nil
        await viewModel.retryRetrospective()

        #expect(client.startTurnTexts.count == 2)
        #expect(viewModel.retrospectiveStatus == .requesting)
        client.onEvent?(.turnCompleted(status: .completed, errorMessage: nil))
        #expect(viewModel.retrospectiveStatus == .prompted)
    }

    @Test @MainActor func recordsRetrospectiveAnswerAndDoesNotPromptTwice() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commandStore = ZileanMCPCommandStore(rootDirectory: directory)
        let client = StubAppServerClient()
        let viewModel = ConversationViewModel(
            client: client,
            harnessPreparer: StubHarnessPreparer(),
            timerCommandStore: commandStore
        )

        await viewModel.connect()
        viewModel.selectDirectory(directory)
        await viewModel.createConversation()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let command = ZileanMCPCommand(
            taskTitle: "응답 기록 작업",
            durationMinutes: 5,
            createdAt: startedAt
        )
        try commandStore.enqueue(command)
        viewModel.processPendingTimerCommands(now: startedAt)
        await viewModel.completeFocusTimer(at: startedAt.addingTimeInterval(30))
        client.onEvent?(.turnCompleted(status: .completed, errorMessage: nil))

        viewModel.draft = "핵심 로직을 정리했고 다음에는 테스트를 보강할게요."
        await viewModel.sendMessage()

        #expect(viewModel.retrospectiveStatus == .answered)
        #expect(viewModel.messages.last?.text == "핵심 로직을 정리했고 다음에는 테스트를 보강할게요.")

        await viewModel.completeFocusTimer(at: startedAt.addingTimeInterval(60))
        #expect(client.startTurnTexts.count == 2)
    }

    @Test @MainActor func savesRetrospectiveAnswerAsWorkLog() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commandStore = ZileanMCPCommandStore(rootDirectory: directory)
        let client = StubAppServerClient()
        let viewModel = ConversationViewModel(
            client: client,
            harnessPreparer: StubHarnessPreparer(),
            timerCommandStore: commandStore
        )
        await viewModel.connect()
        viewModel.selectDirectory(directory)
        await viewModel.createConversation()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try commandStore.enqueue(
            ZileanMCPCommand(
                taskTitle: "작업 기록 저장",
                durationMinutes: 25,
                createdAt: startedAt
            )
        )
        viewModel.processPendingTimerCommands(now: startedAt)
        await viewModel.completeFocusTimer(at: startedAt.addingTimeInterval(90))
        client.onEvent?(.turnCompleted(status: .completed, errorMessage: nil))
        viewModel.draft = "핵심 흐름을 정리했고 다음에는 QMD 색인을 검토한다."

        await viewModel.sendMessage()

        let recordsDirectory = directory.appendingPathComponent("work-records", isDirectory: true)
        let dateDirectory = try #require(
            try FileManager.default.contentsOfDirectory(
                at: recordsDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        let recordURL = try #require(
            try FileManager.default.contentsOfDirectory(
                at: dateDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        let markdown = try String(contentsOf: recordURL, encoding: .utf8)

        #expect(viewModel.retrospectiveStatus == .answered)
        #expect(markdown.contains("# 작업 기록 저장"))
        #expect(markdown.contains("핵심 흐름을 정리했고 다음에는 QMD 색인을 검토한다."))
    }

    @Test @MainActor func startsFocusTimerFromDirectSetup() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let viewModel = ConversationViewModel(
            client: StubAppServerClient(),
            harnessPreparer: StubHarnessPreparer(),
            timerCommandStore: ZileanMCPCommandStore(rootDirectory: directory)
        )
        await viewModel.connect()
        viewModel.selectDirectory(directory)
        await viewModel.createConversation()

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let response = viewModel.startFocusTimer(
            taskTitle: "DART 공시 작업",
            durationMinutes: 25,
            at: startedAt
        )

        #expect(response.success)
        #expect(viewModel.focusTimer?.taskTitle == "DART 공시 작업")
        #expect(viewModel.focusTimer?.durationMinutes == 25)
        #expect(viewModel.focusTimer?.startedAt == startedAt)
        #expect(viewModel.activeWork?.title == "DART 공시 작업")
    }

    @Test @MainActor func directFocusTimerRejectsInvalidDuration() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let viewModel = ConversationViewModel(
            client: StubAppServerClient(),
            harnessPreparer: StubHarnessPreparer(),
            timerCommandStore: ZileanMCPCommandStore(rootDirectory: directory)
        )
        await viewModel.connect()
        viewModel.selectDirectory(directory)
        await viewModel.createConversation()

        let response = viewModel.startFocusTimer(
            taskTitle: "DART 공시 작업",
            durationMinutes: 0
        )

        #expect(!response.success)
        #expect(response.errorCode == "invalid_arguments")
        #expect(viewModel.focusTimer == nil)
    }

    @Test @MainActor func directFocusTimerRequiresActiveWork() {
        let viewModel = ConversationViewModel(
            client: StubAppServerClient(),
            harnessPreparer: StubHarnessPreparer()
        )

        let response = viewModel.startFocusTimer(
            taskTitle: "DART 공시 작업",
            durationMinutes: 25
        )

        #expect(!response.success)
        #expect(response.errorCode == "missing_active_work")
        #expect(viewModel.focusTimer == nil)
    }

    @Test @MainActor func rejectsSecondTimerWhileOneIsRunning() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commandStore = ZileanMCPCommandStore(rootDirectory: directory)
        let client = StubAppServerClient()
        let viewModel = ConversationViewModel(
            client: client,
            harnessPreparer: StubHarnessPreparer(),
            timerCommandStore: commandStore
        )
        await viewModel.connect()
        viewModel.selectDirectory(directory)
        await viewModel.createConversation()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let firstCommand = ZileanMCPCommand(
            taskTitle: "첫 번째 작업",
            durationMinutes: 25,
            createdAt: now
        )
        try commandStore.enqueue(firstCommand)
        viewModel.processPendingTimerCommands(now: now)
        let secondCommand = ZileanMCPCommand(
            taskTitle: "두 번째 작업",
            durationMinutes: 10,
            createdAt: now
        )
        try commandStore.enqueue(secondCommand)

        viewModel.processPendingTimerCommands(now: now)

        let storedResponse = try commandStore.readResponse(for: secondCommand.id)
        let response = try #require(storedResponse)
        #expect(!response.success)
        #expect(response.errorCode == "timer_already_running")
        #expect(viewModel.focusTimer?.taskTitle == "첫 번째 작업")
        #expect(viewModel.recentWorkSessions.map(\.id) == [viewModel.focusTimer?.workID].compactMap { $0 })
    }

    @Test @MainActor func doesNotAddRecentWorkForExpiredTimerCommand() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commandStore = ZileanMCPCommandStore(rootDirectory: directory)
        let viewModel = ConversationViewModel(
            client: StubAppServerClient(),
            harnessPreparer: StubHarnessPreparer(),
            timerCommandStore: commandStore
        )
        await viewModel.connect()
        viewModel.selectDirectory(directory)
        await viewModel.createConversation()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let command = ZileanMCPCommand(
            taskTitle: "만료된 작업",
            durationMinutes: 25,
            createdAt: now.addingTimeInterval(-11)
        )
        try commandStore.enqueue(command)

        viewModel.processPendingTimerCommands(now: now)

        let response = try #require(try commandStore.readResponse(for: command.id))
        #expect(!response.success)
        #expect(response.errorCode == "expired_request")
        #expect(viewModel.recentWorkSessions.isEmpty)
    }

    @Test @MainActor func mergesAgentDeltasInArrivalOrder() async {
        let client = StubAppServerClient()
        let viewModel = ConversationViewModel(client: client, harnessPreparer: StubHarnessPreparer())

        await viewModel.connect()
        viewModel.selectDirectory(URL(fileURLWithPath: "/tmp/delta-test"))
        await viewModel.createConversation()

        client.onEvent?(.agentMessageDelta(itemID: "item-1", text: "안녕"))
        client.onEvent?(.agentMessageDelta(itemID: "item-1", text: "하세요"))
        client.onEvent?(.agentMessageDelta(itemID: "item-1", text: "!"))

        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages[0].role == .agent)
        #expect(viewModel.messages[0].text == "안녕하세요!")
    }

    @Test @MainActor func createsNewAgentMessageForDifferentItem() async {
        let client = StubAppServerClient()
        let viewModel = ConversationViewModel(client: client, harnessPreparer: StubHarnessPreparer())

        await viewModel.connect()
        viewModel.selectDirectory(URL(fileURLWithPath: "/tmp/item-test"))
        await viewModel.createConversation()

        client.onEvent?(.agentMessageDelta(itemID: "item-1", text: "첫 번째"))
        client.onEvent?(.agentMessageDelta(itemID: "item-2", text: "두 번째"))

        #expect(viewModel.messages.map(\.text) == ["첫 번째", "두 번째"])
    }

    @Test @MainActor func preservesMessagesWhenSwitchingWorkSessions() async {
        let client = StubAppServerClient()
        let viewModel = ConversationViewModel(client: client, harnessPreparer: StubHarnessPreparer())

        await viewModel.connect()
        viewModel.selectDirectory(URL(fileURLWithPath: "/tmp/first-work"))
        await viewModel.createConversation()
        let firstWorkID = try! #require(viewModel.activeWorkID)

        viewModel.draft = "첫 번째 작업 정리"
        await viewModel.sendMessage()
        client.onEvent?(.turnCompleted(status: .completed, errorMessage: nil))

        viewModel.selectDirectory(URL(fileURLWithPath: "/tmp/second-work"))
        await viewModel.createConversation()
        let secondWorkID = try! #require(viewModel.activeWorkID)
        viewModel.draft = "두 번째 작업 시작"
        await viewModel.sendMessage()
        client.onEvent?(.turnCompleted(status: .completed, errorMessage: nil))

        #expect(firstWorkID != secondWorkID)
        #expect(viewModel.workSessions.count == 2)
        #expect(viewModel.recentWorkSessions.isEmpty)

        viewModel.selectWork(id: firstWorkID)

        #expect(viewModel.activeWorkID == firstWorkID)
        #expect(viewModel.selectedDirectory?.lastPathComponent == "first-work")
        #expect(viewModel.activeWork?.title == "첫 번째 작업 정리")
        #expect(viewModel.messages.map(\.text) == ["첫 번째 작업 정리"])
    }

    @Test @MainActor func createsZileanInstructionsInSelectedDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try CodexHarnessPreparer().prepare(in: directory)

        let instructionsURL = directory.appendingPathComponent("AGENTS.md")
        let instructions = try String(contentsOf: instructionsURL, encoding: .utf8)
        #expect(instructions == CodexHarnessPreparer.instructions)
    }

    @Test @MainActor func preservesExistingAgentInstructions() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let instructionsURL = directory.appendingPathComponent("AGENTS.md")
        let existingInstructions = "사용자가 작성한 기존 지침"
        try existingInstructions.write(to: instructionsURL, atomically: true, encoding: .utf8)

        try CodexHarnessPreparer().prepare(in: directory)

        let instructions = try String(contentsOf: instructionsURL, encoding: .utf8)
        #expect(instructions == existingInstructions)
    }

    @Test @MainActor func failsWhenAgentsPathIsDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("AGENTS.md"),
            withIntermediateDirectories: false
        )

        #expect(throws: CodexHarnessPreparationError.self) {
            try CodexHarnessPreparer().prepare(in: directory)
        }
    }

    @Test @MainActor func preparesHarnessBeforeStartingThread() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = StubAppServerClient()
        client.onStartThread = { directory in
            let instructionsURL = directory.appendingPathComponent("AGENTS.md")
            return try? String(contentsOf: instructionsURL, encoding: .utf8)
        }
        let viewModel = ConversationViewModel(client: client)

        await viewModel.connect()
        viewModel.selectDirectory(directory)
        await viewModel.createConversation()

        #expect(client.instructionsAtThreadStart == CodexHarnessPreparer.instructions)
        #expect(viewModel.phase == .idle)
    }

    @Test @MainActor func doesNotStartThreadWhenHarnessPreparationFails() async {
        let client = StubAppServerClient()
        let viewModel = ConversationViewModel(
            client: client,
            harnessPreparer: StubHarnessPreparer(error: TestError.preparationFailed)
        )

        await viewModel.connect()
        viewModel.selectDirectory(URL(fileURLWithPath: "/unwritable-folder"))
        await viewModel.createConversation()

        #expect(client.startThreadCallCount == 0)
        #expect(viewModel.phase == .failed(TestError.preparationFailed.localizedDescription))
        #expect(viewModel.workSessions.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

@MainActor
private final class StubAppServerClient: CodexAppServerServing {
    var onEvent: ((AppServerEvent) -> Void)?
    var isConnected = false
    var onStartThread: ((URL) -> String?)?
    var startTurnError: Error?
    private(set) var instructionsAtThreadStart: String?
    private(set) var startTurnTexts: [String] = []
    private(set) var startThreadCallCount = 0
    private var nextThreadIndex = 0

    func connect() async throws {
        isConnected = true
    }

    func startThread(in directory: URL) async throws -> String {
        startThreadCallCount += 1
        instructionsAtThreadStart = onStartThread?(directory)
        nextThreadIndex += 1
        return "thread-\(nextThreadIndex)"
    }

    func startTurn(threadID: String, text: String) async throws -> String {
        startTurnTexts.append(text)
        if let startTurnError {
            throw startTurnError
        }
        return "turn-\(startTurnTexts.count)"
    }

    func stop() {
        isConnected = false
    }
}

private struct StubHarnessPreparer: CodexHarnessPreparing {
    var error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func prepare(in directory: URL) throws {
        if let error {
            throw error
        }
    }
}

private enum TestError: LocalizedError {
    case preparationFailed

    var errorDescription: String? {
        "하네스 준비 실패"
    }
}
