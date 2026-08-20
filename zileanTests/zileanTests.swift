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

    @Test @MainActor func mergesAgentDeltasInArrivalOrder() async {
        let client = StubAppServerClient()
        let viewModel = ConversationViewModel(client: client)

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
        let viewModel = ConversationViewModel(client: client)

        await viewModel.connect()
        viewModel.selectDirectory(URL(fileURLWithPath: "/tmp/item-test"))
        await viewModel.createConversation()

        client.onEvent?(.agentMessageDelta(itemID: "item-1", text: "첫 번째"))
        client.onEvent?(.agentMessageDelta(itemID: "item-2", text: "두 번째"))

        #expect(viewModel.messages.map(\.text) == ["첫 번째", "두 번째"])
    }

    @Test @MainActor func preservesMessagesWhenSwitchingWorkSessions() async {
        let client = StubAppServerClient()
        let viewModel = ConversationViewModel(client: client)

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
        #expect(Set(viewModel.recentWorkSessions.map(\.id)) == Set([firstWorkID, secondWorkID]))

        viewModel.selectWork(id: firstWorkID)

        #expect(viewModel.activeWorkID == firstWorkID)
        #expect(viewModel.selectedDirectory?.lastPathComponent == "first-work")
        #expect(viewModel.activeWork?.title == "첫 번째 작업 정리")
        #expect(viewModel.messages.map(\.text) == ["첫 번째 작업 정리"])
    }
}

@MainActor
private final class StubAppServerClient: CodexAppServerServing {
    var onEvent: ((AppServerEvent) -> Void)?
    var isConnected = false
    private var nextThreadIndex = 0

    func connect() async throws {
        isConnected = true
    }

    func startThread(in directory: URL) async throws -> String {
        nextThreadIndex += 1
        return "thread-\(nextThreadIndex)"
    }

    func startTurn(threadID: String, text: String) async throws -> String {
        "turn-1"
    }

    func stop() {
        isConnected = false
    }
}
