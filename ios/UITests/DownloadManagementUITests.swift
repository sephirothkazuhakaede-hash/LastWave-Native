import XCTest

final class DownloadManagementUITests: XCTestCase {
    func testPlaylistDeletionRequiresConfirmationAndSongMenuIsClean() {
        let app = XCUIApplication()
        app.launchArguments = ["--layout-fixture", "playlist"]
        app.launch()
        let songMenu = app.buttons["song-menu-fixture00001"]
        XCTAssertTrue(songMenu.waitForExistence(timeout: 8))
        if !songMenu.isHittable { app.swipeUp() }
        songMenu.tap()
        for name in ["Play now", "Play next", "Add to queue", "Add to playlist", "Download"] {
            XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 3), name)
        }
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'MSI' OR label CONTAINS[c] 'cache hit'")).firstMatch.exists)
        app.tapCoordinateOutsideMenu()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["Play now"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 4), .completed)
        let menu = app.buttons["playlist-management-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 4))
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); app.buttons["Delete playlist"].tap()
        let alert = app.alerts["Delete playlist?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 4))
        XCTAssertTrue(alert.staticTexts["The playlist will be removed. Downloaded songs will stay on this iPhone."].exists)
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(menu.exists, "Cancel must keep the playlist")
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); app.buttons["Delete playlist"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 4))
        alert.buttons["Delete playlist"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: menu)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 4), .completed)
    }
}

private extension XCUIApplication {
    func tapCoordinateOutsideMenu() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.20)).tap()
    }
}
