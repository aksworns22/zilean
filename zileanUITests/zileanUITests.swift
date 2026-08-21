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

    func testWorkspaceLayoutAppears() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        XCTAssertTrue(app.buttons["새 작업"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["돌아보기"].exists)
        XCTAssertTrue(app.staticTexts["오늘은 어떤 작업을 시작할까요?"].exists)
        XCTAssertTrue(app.buttons["타이머 직접 설정"].exists)
        XCTAssertTrue(app.buttons["메시지 보내기"].exists)
        XCTAssertFalse(app.staticTexts["로컬 사용자"].exists)
        XCTAssertFalse(app.staticTexts["완료"].exists)
        XCTAssertEqual(app.progressIndicators.count, 0)

        app.buttons["타이머 직접 설정"].click()
        XCTAssertTrue(app.staticTexts["타이머 직접 설정"].exists)
        XCTAssertTrue(app.buttons["집중 시간 25분"].exists)
        XCTAssertTrue(app.buttons["집중 시간 45분"].exists)
        XCTAssertTrue(app.buttons["집중 시간 1시간"].exists)
        XCTAssertTrue(app.buttons["집중 시간 2시간"].exists)
        XCTAssertTrue(app.buttons["집중 타이머 시작"].exists)
        app.buttons["타이머 설정 닫기"].firstMatch.click()

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
