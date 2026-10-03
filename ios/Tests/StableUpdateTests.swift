import XCTest
@testable import CapyFlow

final class StableUpdateTests: XCTestCase {
    private func manifest(version: String = "0.4.6", build: Int = 13, channel: String = "stable", url: String = "https://github.com/sephirothkazuhakaede-hash/LastWave-Native/releases") throws -> StableUpdateManifest {
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "channel": channel,
            "version": version, "build": build, "releaseNotes": "Fixture release notes", "installURL": url])
        return try JSONDecoder().decode(StableUpdateManifest.self, from: data)
    }
    func testSameOlderAndNewerVersionsAndBuilds() throws {
        let current = try XCTUnwrap(AppReleaseVersion(version: "0.4.5", build: 12))
        XCTAssertFalse(try manifest(version: "0.4.5", build: 12).isNewer(than: current))
        XCTAssertFalse(try manifest(version: "0.4.4", build: 100).isNewer(than: current))
        XCTAssertFalse(try manifest(version: "0.4.5", build: 11).isNewer(than: current))
        XCTAssertTrue(try manifest(version: "0.4.5", build: 13).isNewer(than: current))
        XCTAssertTrue(try manifest().isNewer(than: current))
        XCTAssertTrue(try manifest(version: "0.10.0", build: 1).isNewer(than: current))
        XCTAssertEqual(AppReleaseVersion(version: "1.2", build: 1), AppReleaseVersion(version: "1.2.0", build: 1))
    }
    func testExperimentalAndMalformedReleasesNeverNotifyStableUsers() throws {
        let current = try XCTUnwrap(AppReleaseVersion(version: "0.4.5", build: 12))
        XCTAssertFalse(try manifest(channel: "experimental").isNewer(than: current))
        XCTAssertFalse(try manifest(version: "0.4.6-beta.1").isNewer(than: current))
        XCTAssertFalse(try manifest(build: 0).isNewer(than: current))
        XCTAssertFalse(try manifest(url: "http://example.com/update").isNewer(than: current))
        XCTAssertNil(AppReleaseVersion(version: "v0.4.6", build: 13))
        XCTAssertNil(AppReleaseVersion(version: "0..4", build: 13))
    }
    func testGitHubDraftPrereleaseAndUnrelatedReleaseTagsAreExcluded() throws {
        for (tag, draft, prerelease, expected) in [
            ("capyflow-v0.4.6", false, false, true),
            ("capyflow-v0.4.6", true, false, false),
            ("capyflow-v0.4.6", false, true, false),
            ("capyflow-v0.4.6-beta", false, false, false),
            ("v2.0.0", false, false, false),
            ("experiment/ui-polish-v1", false, false, false)
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": prerelease, "assets": []])
            let release = try JSONDecoder().decode(GitHubStableRelease.self, from: data)
            XCTAssertEqual(release.isEligible, expected)
        }
    }

    func testFirstStableReleaseUpdatesInstalledMessagingBuild() throws {
        let installed = try XCTUnwrap(AppReleaseVersion(version: "0.4.9", build: 16))
        XCTAssertTrue(try manifest(version: "0.4.10", build: 17).isNewer(than: installed))
        XCTAssertFalse(try manifest(version: "0.4.9", build: 16).isNewer(than: installed))
        XCTAssertFalse(try manifest(version: "0.4.10", build: 17, channel: "experimental").isNewer(than: installed))
    }

}
