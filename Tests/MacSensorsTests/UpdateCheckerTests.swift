import Foundation
import Testing
@testable import FixStatCore

@Suite struct UpdateCheckerTests {
    @Test func versionOrder() {
        #expect(UpdateChecker.isNewer("1.3", than: "1.2.1"))
        #expect(UpdateChecker.isNewer("1.10.0", than: "1.9.2"))
        #expect(UpdateChecker.isNewer("1.2.1", than: "1.2"))
        #expect(!UpdateChecker.isNewer("1.2.1", than: "1.2.1"))
        #expect(!UpdateChecker.isNewer("1.2", than: "1.2.0"))
        #expect(!UpdateChecker.isNewer("1.1.9", than: "1.2"))
    }

    @Test func parsesTheReleasesAPI() throws {
        // Shape of api.github.com/repos/BurakFixLab/fixstat/releases/latest (checked 2026-10-07).
        let json = #"{"tag_name":"v1.2.1","html_url":"https://github.com/BurakFixLab/fixstat/releases/tag/v1.2.1","draft":false,"prerelease":false,"name":"FixStat 1.2.1"}"#
        let release = try #require(UpdateChecker.parse(Data(json.utf8)))
        #expect(release.version == "1.2.1")
        #expect(release.url.absoluteString.hasSuffix("/v1.2.1"))
        let beta = #"{"tag_name":"v1.3.0-beta","prerelease":true}"#
        #expect(UpdateChecker.parse(Data(beta.utf8)) == nil)
        #expect(UpdateChecker.parse(Data("not json".utf8)) == nil)
    }
}
