//
//  zileanUITests.swift
//  zileanUITests
//
//  Created by 장대한 on 8/20/26.
//

import XCTest

final class zileanUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testWorkspaceLayoutAppears() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["새 작업"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["돌아보기"].exists)
        XCTAssertTrue(app.staticTexts["오늘은 어떤 작업을 시작할까요?"].exists)
        XCTAssertTrue(app.buttons["작업 폴더 선택"].exists)
        XCTAssertTrue(app.buttons["메시지 보내기"].exists)

        app.buttons["돌아보기"].click()
        XCTAssertTrue(app.staticTexts["아직 돌아볼 작업이 없어요"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
