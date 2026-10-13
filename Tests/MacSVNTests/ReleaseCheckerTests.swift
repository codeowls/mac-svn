import Foundation
import Testing
@testable import SVNCore
@testable import MacSVN

@MainActor
struct ReleaseCheckerTests {
    @Test func versionsCompareNumericallyAndRejectUnsupportedFormats() throws {
        #expect(try AppVersion("1.9.9") < AppVersion("1.10.0"))
        #expect(try AppVersion("2.0.0") > AppVersion("1.999.999"))
        #expect(try AppVersion("1.5.0") == AppVersion("1.5.0"))
        for value in ["", "1.5", "1.5.0.1", "01.5.0", "-1.5.0", "1.5.0-beta", "9999999999999999999999.0.0"] {
            #expect(throws: SVNError.self) { try AppVersion(value) }
        }
    }

    @Test func responsesDistinguishCurrentNewAndDevelopmentVersions() throws {
        let data = try fixture(tag: "v1.5.0")
        let current = try ReleaseCheckResult.parse(currentVersion: "1.5.0", data: data, response: response(200))
        #expect(current.comparison == .orderedSame)
        #expect(current.release.body == "Published release notes")
        #expect(try ReleaseCheckResult.parse(currentVersion: "1.4.9", data: data, response: response(200)).comparison == .orderedAscending)
        #expect(try ReleaseCheckResult.parse(currentVersion: "1.6.0", data: data, response: response(200)).comparison == .orderedDescending)
        let emptyNotes = try fixture(tag: "v1.5.0", notes: nil)
        #expect(try ReleaseCheckResult.parse(currentVersion: "1.5.0", data: emptyNotes, response: response(200)).release.body == nil)
    }

    @Test func failuresAndForeignLinksCannotReportUpToDate() throws {
        let valid = try fixture(tag: "v1.5.0")
        for code in [403, 404, 429, 500] {
            #expect(throws: SVNError.self) {
                try ReleaseCheckResult.parse(currentVersion: "1.5.0", data: valid, response: response(code))
            }
        }
        for data in [
            try fixture(tag: "v1.5.0", page: "https://example.com/codeowls/mac-svn/releases/tag/v1.5.0"),
            try fixture(tag: "v1.5.0", page: "https://github.com/other/repo/releases/tag/v1.5.0"),
            try fixture(tag: "v1.5.0", prerelease: true),
            try fixture(tag: "v1.5.0", draft: true),
            try fixture(tag: "unexpected")
        ] {
            #expect(throws: SVNError.self) {
                try ReleaseCheckResult.parse(currentVersion: "1.5.0", data: data, response: response(200))
            }
        }
        #expect(throws: (any Error).self) {
            try ReleaseCheckResult.parse(currentVersion: "1.5.0", data: Data("invalid".utf8), response: response(200))
        }
    }

    @Test func checkerUsesPublicRequestAndCancelledResultsStayClosed() async throws {
        let data = try fixture(tag: "v1.5.0")
        let http = response(200)
        let checker = ReleaseChecker(currentVersion: "1.5.0", fetch: { request in
            #expect(request.url == ReleaseChecker.endpoint)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(!request.httpShouldHandleCookies)
            return (data, http)
        })
        checker.check()
        try await waitUntil { !checker.isChecking }
        if case .checked(let result) = checker.state {
            #expect(result.comparison == .orderedSame)
        } else { Issue.record("Expected a checked release") }
        let delayed = ReleaseChecker(currentVersion: "1.5.0", fetch: { _ in
            try await Task.sleep(for: .milliseconds(100))
            return (data, http)
        })
        delayed.check()
        delayed.cancel()
        try await Task.sleep(for: .milliseconds(150))
        if case .idle = delayed.state {} else { Issue.record("Cancelled request repopulated the view") }
        let missingVersion = ReleaseChecker(currentVersion: nil, fetch: { _ in
            Issue.record("An unversioned app must not request release data")
            return (data, http)
        })
        missingVersion.check()
        try await waitUntil { !missingVersion.isChecking }
        if case .failed = missingVersion.state {} else { Issue.record("Missing version was not reported") }
    }

    private func fixture(tag: String, page: String? = nil, notes: String? = "Published release notes", prerelease: Bool = false, draft: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "html_url": page ?? "https://github.com/codeowls/mac-svn/releases/tag/" + tag,
            "body": notes as Any? ?? NSNull(), "published_at": "2026-10-01T00:00:00Z",
            "prerelease": prerelease, "draft": draft
        ])
    }

    private func response(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: ReleaseChecker.endpoint, statusCode: code, httpVersion: "HTTP/1.1", headerFields: [:])!
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition())
    }
}
