import XCTest
import FirebaseFirestore
@testable import CapyFlow

final class MessagingTests: XCTestCase {
    func testConversationIdentityAndReadStatus() throws {
        XCTAssertEqual(DirectConversation.id(for: "bob", and: "alice"), DirectConversation.id(for: "alice", and: "bob"))
        let data: [String: Any] = ["memberIDs": ["alice", "bob"], "lastMessageID": "message", "lastText": "Hello", "lastSenderID": "alice",
                                   "updatedAt": Timestamp(date: Date()), "readMessageIDs": ["alice": "message", "bob": "older"]]
        let thread = try XCTUnwrap(DirectConversation(id: "alice_bob", data: data))
        XCTAssertFalse(thread.isUnread(for: "alice"))
        XCTAssertTrue(thread.isUnread(for: "bob"))
        XCTAssertFalse(thread.isUnread(for: "mallory"))
        XCTAssertEqual(thread.peerID(for: "alice"), "bob")
        var read = data; read["readMessageIDs"] = ["alice": "message", "bob": "message"]
        XCTAssertFalse(try XCTUnwrap(DirectConversation(id: "alice_bob", data: read)).isUnread(for: "bob"))
        var invalid = data; invalid["memberIDs"] = ["alice", "alice"]
        XCTAssertNil(DirectConversation(id: "invalid", data: invalid))
    }
    func testOutgoingStatusUsesPeerReadWatermark() {
        let ids = ["first", "second", "third"]
        XCTAssertEqual(DirectMessageStatus.resolve(messageID: "first", pending: true, peerReadID: "third", orderedIDs: ids), .sending)
        XCTAssertEqual(DirectMessageStatus.resolve(messageID: "first", pending: false, peerReadID: nil, orderedIDs: ids), .sent)
        XCTAssertEqual(DirectMessageStatus.resolve(messageID: "first", pending: false, peerReadID: "second", orderedIDs: ids), .read)
        XCTAssertEqual(DirectMessageStatus.resolve(messageID: "second", pending: false, peerReadID: "second", orderedIDs: ids), .read)
        XCTAssertEqual(DirectMessageStatus.resolve(messageID: "third", pending: false, peerReadID: "second", orderedIDs: ids), .sent)
        XCTAssertEqual(DirectMessageStatus.resolve(messageID: "third", pending: false, peerReadID: "unknown", orderedIDs: ids), .sent)
    }

    func testMessageInputBoundsAndWhitespace() {
        XCTAssertEqual(DirectMessage.cleaned("  Hello\n"), "Hello")
        XCTAssertNil(DirectMessage.cleaned("\n  "))
        XCTAssertNotNil(DirectMessage.cleaned(String(repeating: "x", count: 4000)))
        XCTAssertNil(DirectMessage.cleaned(String(repeating: "x", count: 4001)))
        XCTAssertNil(DirectMessage.cleaned(String(repeating: "🙂", count: 2001)))
    }
    func testArrivalBaselineCacheDuplicatesAndOpenChat() throws {
        func thread(_ message: String, sender: String = "alice") throws -> DirectConversation {
            try XCTUnwrap(DirectConversation(id: "alice_bob", data: ["memberIDs": ["alice", "bob"], "lastMessageID": message,
                "lastText": "Hello", "lastSenderID": sender, "updatedAt": Timestamp(date: Date()), "readMessageIDs": ["bob": "old"]]))
        }
        var tracker = MessageArrivalTracker()
        XCTAssertNil(tracker.receive([try thread("cached")], uid: "bob", fromCache: true, activePeerID: nil))
        XCTAssertNil(tracker.receive([try thread("baseline")], uid: "bob", fromCache: false, activePeerID: nil))
        XCTAssertEqual(tracker.receive([try thread("new")], uid: "bob", fromCache: false, activePeerID: nil)?.id, "new")
        XCTAssertNil(tracker.receive([try thread("new")], uid: "bob", fromCache: false, activePeerID: nil))
        XCTAssertNil(tracker.receive([try thread("open")], uid: "bob", fromCache: false, activePeerID: "alice"))
        XCTAssertNil(tracker.receive([try thread("mine", sender: "bob")], uid: "bob", fromCache: false, activePeerID: nil))
    }

}
