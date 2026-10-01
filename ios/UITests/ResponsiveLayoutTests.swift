import XCTest

final class ResponsiveLayoutTests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    func testPrimaryScreensStayInsideTheDisplay() throws {
        for fixture in ["player", "player-lyrics", "album", "playlist", "social", "profile"] {
            launch(fixture)
            assertVisibleControlsFitHorizontally(screen: fixture)
            attachScreenshot(named: fixture)
            app.terminate()
        }
    }

    func testHomeSearchAndLibraryStayInsideTheDisplay() throws {
        launch("root")
        assertVisibleControlsFitHorizontally(screen: "home")

        app.buttons["home-profile-menu"].tap()
        let closeDrawer = app.buttons["Close profile menu"]
        XCTAssertTrue(closeDrawer.waitForExistence(timeout: 4))
        assertVisibleControlsFitHorizontally(screen: "profile drawer")
        attachScreenshot(named: "profile-drawer")

        app.buttons["Profile & friends"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 4))
        assertVisibleControlsFitHorizontally(screen: "profile page sheet")
        attachScreenshot(named: "profile-page-sheet")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForNonExistence(timeout: 4))

        app.buttons["home-profile-menu"].tap()
        XCTAssertTrue(closeDrawer.waitForExistence(timeout: 4))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 4))
        assertVisibleControlsFitHorizontally(screen: "settings sheet")
        attachScreenshot(named: "settings-sheet")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 4))

        app.buttons["Search"].tap()
        XCTAssertTrue(staticText(containing: "Songs, artists, albums and your playlists").waitForExistence(timeout: 4))
        assertVisibleControlsFitHorizontally(screen: "search")

        app.buttons["Library"].tap()
        XCTAssertTrue(staticText(containing: "Everything you made yours").waitForExistence(timeout: 4))
        assertVisibleControlsFitHorizontally(screen: "library")
        attachScreenshot(named: "root-tabs")
    }

    private func launch(_ fixture: String) {
        app = XCUIApplication()
        app.launchArguments = ["--layout-fixture", fixture]
        app.launchEnvironment["CAPYFLOW_DISABLE_ANIMATIONS"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 12), "\(fixture) did not present a window")
        XCTAssertTrue(
            fixtureMarker(for: fixture).waitForExistence(timeout: 12),
            "\(fixture) did not finish rendering its expected content"
        )
    }

    private func fixtureMarker(for fixture: String) -> XCUIElement {
        switch fixture {
        case "player", "player-lyrics":
            return app.staticTexts["A Very Long Album Song Title That Must Never Push Controls Outside the Phone"]
        case "album":
            return app.staticTexts["An Album With a Deliberately Long Name for Responsive Layout Testing"].firstMatch
        case "playlist":
            return app.staticTexts["A Very Long Shared Road Trip Playlist Name"].firstMatch
        case "social":
            return app.navigationBars["Profile & Friends"]
        case "profile":
            return app.navigationBars["Profile"]
        default:
            return app.staticTexts["CapyFlow"].firstMatch
        }
    }

    private func staticText(containing value: String) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", value))
            .firstMatch
    }

    /// A regression guard for the 0.4.1 bug where full-width content received
    /// horizontal padding afterwards and reported a width larger than its phone.
    /// Intentional off-screen items in horizontal scrollers are not hittable and
    /// are therefore excluded from this visible-control check.
    private func assertVisibleControlsFitHorizontally(screen: String) {
        let window = app.windows.firstMatch
        let bounds = window.frame
        let tolerance: CGFloat = 1.5
        let candidates = app.descendants(matching: .any).allElementsBoundByIndex

        for element in candidates where element.exists && element.isHittable {
            let frame = element.frame
            guard !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0 else { continue }
            guard frame.maxY >= bounds.minY, frame.minY <= bounds.maxY else { continue }
            XCTAssertGreaterThanOrEqual(
                frame.minX,
                bounds.minX - tolerance,
                "\(screen): \(description(of: element)) begins outside the display (\(frame))"
            )
            XCTAssertLessThanOrEqual(
                frame.maxX,
                bounds.maxX + tolerance,
                "\(screen): \(description(of: element)) ends outside the display (\(frame))"
            )
        }
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func description(of element: XCUIElement) -> String {
        if !element.identifier.isEmpty { return element.identifier }
        if !element.label.isEmpty { return "\(element.elementType) ‘\(element.label)’" }
        return String(describing: element.elementType)
    }
}
