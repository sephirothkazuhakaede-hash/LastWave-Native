import XCTest
@testable import CapyFlow

final class SocialConnectionTests: XCTestCase {
    func testCachedProfileNeverInventsOfflineOrErasesCurrentConnectionState() {
        for state in [SocialConnectionState.connecting, .ready, .offline, .setupRequired] {
            XCTAssertEqual(state.receivingProfileSnapshot(isFromCache: true, exists: true), state)
        }
        XCTAssertEqual(SocialConnectionState.connecting.receivingProfileSnapshot(isFromCache: true, exists: false), .connecting)
    }
    func testServerProfileEstablishesConnectivityAndRetryCanRecover() {
        XCTAssertEqual(SocialConnectionState.connecting.receivingProfileSnapshot(isFromCache: false, exists: true), .ready)
        XCTAssertEqual(SocialConnectionState.offline.receivingProfileSnapshot(isFromCache: false, exists: true), .ready)
        XCTAssertEqual(SocialConnectionState.connecting.receivingProfileSnapshot(isFromCache: false, exists: false), .connecting)
        XCTAssertEqual(SocialConnectionState.setupRequired.receivingProfileSnapshot(isFromCache: false, exists: true), .setupRequired)
    }
}
