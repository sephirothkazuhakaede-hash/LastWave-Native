import XCTest

final class HomeDockUITests: XCTestCase {
    func testProfilePreviewShowsSharedListeningActivity() {
        let app = XCUIApplication()
        app.launchArguments = ["--layout-fixture", "person"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Listening now"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["River Glass"].exists)
        XCTAssertTrue(app.staticTexts["CapyFlow Friends"].exists)
    }

    func testConversationComposerStaysVisibleWithMusicAndKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["--layout-fixture", "chat"]
        app.launch()
        let composer = app.descendants(matching: .any).matching(identifier: "chat-message-field").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        let music = app.otherElements["chat-music-controls"]
        XCTAssertTrue(music.waitForExistence(timeout: 4))
        XCTAssertFalse(app.otherElements["capy-dock"].exists)
        XCTAssertTrue(composer.isHittable)
        XCTAssertLessThanOrEqual(music.frame.maxY, composer.frame.minY + 1)
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        composer.typeText("Hello")
        XCTAssertTrue(composer.isHittable)
        XCTAssertLessThanOrEqual(composer.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        XCTAssertLessThanOrEqual(music.frame.maxY, composer.frame.minY + 1)
        XCTAssertTrue(app.buttons["Open Now Playing"].isHittable)
    }

    func testMessagesIsAvailableInMainNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["--layout-fixture", "root"]
        app.launch()
        let dock = app.otherElements["capy-dock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 8))
        let messages = dock.buttons["Messages"]
        XCTAssertTrue(messages.isHittable)
        messages.tap()
        XCTAssertTrue(app.navigationBars["Messages"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Sign in to message friends"].exists)
        dock.buttons["Home"].tap()
        XCTAssertTrue(app.scrollViews["home-scroll"].isHittable)
    }

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
        XCTAssertTrue(footer.label.contains("Version 0.4.11, Build 24"))
        XCTAssertTrue(footer.label.contains("by Seph"))
        friends.tap()
        XCTAssertTrue(app.staticTexts["Find people"].waitForExistence(timeout: 4))
    }
}
