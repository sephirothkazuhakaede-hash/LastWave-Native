import XCTest
import FirebaseFirestore
@testable import CapyFlow

final class FriendActivityTests: XCTestCase {
    func testExpiredOrPausedPresenceNeverAppearsActivelyListening() throws {
        let now = Date(timeIntervalSince1970: 10000)
        let data: [String: Any] = ["title": "Fixture", "artist": "Artist", "videoID": "abcdefghijk", "playing": true,
            "updatedAt": Timestamp(date: now.addingTimeInterval(-20)), "expiresAt": Timestamp(date: now.addingTimeInterval(280))]
        let active = try XCTUnwrap(FriendListeningActivity(id: "friend", data: data))
        XCTAssertTrue(active.isListening(at: now))
        XCTAssertFalse(active.isListening(at: now.addingTimeInterval(301)))
        var paused = data; paused["playing"] = false
        XCTAssertFalse(try XCTUnwrap(FriendListeningActivity(id: "friend", data: paused)).isListening(at: now))
        XCTAssertTrue(active.canPlay)
        var unplayable = data; unplayable["videoID"] = "metadata-only"
        XCTAssertFalse(try XCTUnwrap(FriendListeningActivity(id: "friend", data: unplayable)).canPlay)
    }
}
