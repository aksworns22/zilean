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
}
