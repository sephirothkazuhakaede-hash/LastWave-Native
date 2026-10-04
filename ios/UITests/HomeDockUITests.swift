import XCTest

final class HomeDockUITests: XCTestCase {
    func testHomeFriendsAndAppInfoRemainAbovePlayingDock() {
        let app = XCUIApplication()
        app.launchArguments = ["--layout-fixture", "root"]
        app.launch()
        let home = app.scrollViews["home-scroll"]
        XCTAssertTrue(home.waitForExistence(timeout: 8))
        let friends = app.buttons["home-friends-shared"]
        let dock = app.otherElements["capy-dock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 8))
        let footer = app.descendants(matching: .any).matching(identifier: "app-info-footer").firstMatch
        for _ in 0..<6 {
            if footer.exists && footer.frame.minY >= home.frame.minY && footer.frame.maxY <= dock.frame.minY { break }
            home.swipeUp()
        }
        print("Home: \(home.frame), friends: \(friends.frame), footer: \(footer.frame), dock: \(dock.frame)")
        XCTAssertTrue(friends.exists)
        XCTAssertTrue(friends.isHittable)
        XCTAssertLessThanOrEqual(friends.frame.maxY, dock.frame.minY + 1)
        XCTAssertTrue(footer.exists)
        XCTAssertGreaterThan(footer.frame.height, 0)
        XCTAssertGreaterThanOrEqual(footer.frame.minY, home.frame.minY - 1)
        XCTAssertLessThanOrEqual(footer.frame.maxY, dock.frame.minY + 1)
        XCTAssertTrue(footer.label.contains("Version 0.4.11, Build 20"))
        XCTAssertTrue(footer.label.contains("by Seph"))
        friends.tap()
        XCTAssertTrue(app.staticTexts["Find people"].waitForExistence(timeout: 4))
    }
}
