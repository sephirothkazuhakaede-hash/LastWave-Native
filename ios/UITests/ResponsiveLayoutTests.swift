import XCTest
import UIKit

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
            assertSafeAreaPixelsHaveBackground(screen: fixture)
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
        let qualityLink = app.buttons["Audio Quality"].firstMatch
        if !qualityLink.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(qualityLink.isHittable, "Audio Quality must be reachable in Settings")
        qualityLink.tap()
        XCTAssertTrue(app.navigationBars["Audio Quality"].waitForExistence(timeout: 4))
        let saver = app.buttons["audio-quality-dataSaver"]
        let best = app.buttons["audio-quality-automatic"]
        XCTAssertTrue(saver.waitForExistence(timeout: 4))
        saver.tap()
        XCTAssertEqual(saver.value as? String, "Selected")
        best.tap()
        XCTAssertEqual(best.value as? String, "Selected")
        assertVisibleControlsFitHorizontally(screen: "audio quality settings")
        attachScreenshot(named: "audio-quality-settings")
        app.navigationBars["Audio Quality"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 4))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 4))

        app.buttons["Search"].tap()
        XCTAssertTrue(staticText(containing: "Songs, artists, albums and your playlists").waitForExistence(timeout: 4))
        assertVisibleControlsFitHorizontally(screen: "search")

        app.buttons["Library"].tap()
        XCTAssertTrue(staticText(containing: "Everything you made yours").waitForExistence(timeout: 4))
        assertVisibleControlsFitHorizontally(screen: "library")
        attachScreenshot(named: "root-tabs")
        let filters = app.scrollViews["library-filter-scroll"]
        let sharedFilter = app.descendants(matching: .any).matching(identifier: "library-filter-Shared").firstMatch
        // Swipe distance varies by device and simulator. Reach the final chip
        // rather than assuming one gesture always lands at the scroll end.
        for _ in 0..<3 {
            if sharedFilter.isHittable && sharedFilter.frame.maxX <= filters.frame.maxX + 1.5 { break }
            filters.swipeLeft()
        }
        XCTAssertTrue(sharedFilter.isHittable, "The last library filter must be reachable by scrolling")
        XCTAssertGreaterThanOrEqual(sharedFilter.frame.minX, filters.frame.minX - 1.5)
        XCTAssertLessThanOrEqual(sharedFilter.frame.maxX, filters.frame.maxX + 1.5)
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

    func testRootBackgroundCoversTopAndBottomSafeAreas() throws {
        launch("root")
        for screen in ["Home", "Search", "Library"] {
            if screen != "Home" { app.buttons[screen].tap() }
            // Inspect rendered screen pixels: SwiftUI accessibility bounds can
            // include off-screen gradient/blur extents even when clipped.
            assertSafeAreaPixelsHaveBackground(screen: screen)
            attachScreenshot(named: "\(screen)-safe-areas")
        }
    }

    private func assertSafeAreaPixelsHaveBackground(screen: String) {
        guard let image = app.screenshot().image.cgImage else { XCTFail("Screenshot unavailable"); return }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        XCTAssertTrue(rendered)
        // Sample away from the status text, camera cutout, and home indicator.
        // A clipped ambient layer leaves an entirely black strip at either edge.
        for row in [2, height - 3] {
            let lit = [0.15, 0.25, 0.75, 0.85].contains { fraction in
                let offset = (row * width + Int(Double(width) * fraction)) * 4
                return Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2]) > 6
            }
            XCTAssertTrue(lit, "\(screen) has a black strip at screen edge \(row)")
        }
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
    /// Horizontal filter buttons are checked inside their clipping viewport;
    /// the final filter is also scrolled fully into view and checked above.
    private func assertVisibleControlsFitHorizontally(screen: String) {
        let window = app.windows.firstMatch
        let bounds = window.frame
        let tolerance: CGFloat = 1.5
        let candidates = app.descendants(matching: .any).allElementsBoundByIndex
        let filters = app.scrollViews["library-filter-scroll"]
        let filterElements = Set(filters.exists ? filters.descendants(matching: .any).allElementsBoundByIndex.map {
            boundsKey(for: $0, frame: $0.frame)
        } : [])
        let filterViewport = filters.exists ? filters.frame : CGRect.null
        if !filterViewport.isNull {
            XCTAssertGreaterThanOrEqual(filterViewport.minX, bounds.minX - tolerance)
            XCTAssertLessThanOrEqual(filterViewport.maxX, bounds.maxX + tolerance)
        }

        for element in candidates where element.exists && element.isHittable {
            var frame = element.frame
            guard !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0 else { continue }
            guard frame.maxY >= bounds.minY, frame.minY <= bounds.maxY else { continue }
            // UIKit's sheet dimming backdrop covers three screen widths and
            // heights. It is a system decoration, not the sheet's content.
            if element.elementType == .other && element.identifier.isEmpty && element.label.isEmpty,
               abs(frame.width - bounds.width * 3) < tolerance,
               abs(frame.height - bounds.height * 3) < tolerance,
               abs(frame.midX - bounds.midX) < tolerance,
               abs(frame.midY - bounds.midY) < tolerance { continue }
            // Match only descendants of the explicitly identified horizontal
            // scroller, including UIKit's anonymous scroll content wrapper.
            if !filterViewport.isNull, frame.intersects(filterViewport),
               filterElements.contains(boundsKey(for: element, frame: frame)) {
                frame = frame.intersection(filterViewport)
                XCTAssertFalse(frame.isNull, "A hittable filter must intersect its scroll viewport")
                guard !frame.isNull else { continue }
            }
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

    private func boundsKey(for element: XCUIElement, frame: CGRect) -> String {
        "\(element.elementType.rawValue)|\(element.identifier)|\(element.label)|\(frame)"
    }

    private func description(of element: XCUIElement) -> String {
        if !element.identifier.isEmpty { return element.identifier }
        if !element.label.isEmpty { return "\(element.elementType) ‘\(element.label)’" }
        return String(describing: element.elementType)
    }
}
