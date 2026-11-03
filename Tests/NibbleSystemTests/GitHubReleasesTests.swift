import Foundation
import NibbleCore
import Testing
@testable import NibbleSystem

/// Finding the latest release from where GitHub's release page points, every way it can go, on a
/// network stand-in: requests never leave the test. `NIBBLE_NETWORK_TESTS=1` also asks GitHub.
@Suite struct GitHubReleasesTests {
    /// Answers requests from a table keyed by URL path; each test uses its own repository name, so
    /// tests running at the same time never see each other's answers.
    final class Stub: URLProtocol, @unchecked Sendable {
        enum Answer {
            /// A redirect, as GitHub answers /releases/latest. Delivered as the answer itself: a
            /// stand-in cannot decline a redirect the way the real network does (that the real one
            /// is not followed is checked against GitHub, `nibblesOwnLatestReleaseOnGitHub`).
            case redirect(String)
            case status(Int, [String: String])
            case failure(URLError.Code)
        }

        nonisolated(unsafe) private static var answers: [String: Answer] = [:]
        nonisolated(unsafe) private static var seen: [String: URLRequest] = [:]
        private static let lock = NSLock()

        static func set(_ path: String, _ answer: Answer) { lock.withLock { answers[path] = answer } }
        static func request(_ path: String) -> URLRequest? { lock.withLock { seen[path] } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!
            let answer = Self.lock.withLock {
                Self.seen[url.path] = request
                return Self.answers[url.path]
            }
            switch answer {
            case .redirect(let location):
                let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            case .status(let code, let headers):
                let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("<html></html>".utf8))
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let code):
                client?.urlProtocol(self, didFailWithError: URLError(code))
            case nil:
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            }
        }

        override func stopLoading() {}

        static let session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [Stub.self]
            configuration.httpShouldSetCookies = false
            return URLSession(configuration: configuration)
        }()
    }

    /// The latest release of `owner/<name>` with GitHub answering `answer`.
    func latest(_ name: String, _ answer: Stub.Answer) async throws -> Release {
        Stub.set("/owner/\(name)/releases/latest", answer)
        return try await GitHubReleases(repository: "owner/\(name)", session: Stub.session).latest()
    }

    @Test func theLatestReleaseIsTheTagItRedirectsTo() async throws {
        let tagPage = "https://github.com/owner/found/releases/tag/v0.1.2"
        let release = try await latest("found", .redirect(tagPage))
        #expect(release.version == AppVersion("0.1.2"))
        #expect(release.page.absoluteString == tagPage)
        let request = try #require(Stub.request("/owner/found/releases/latest"))
        #expect(request.url?.host == "github.com")
        // Nothing about the reader.
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aRelativeRedirectIsReadAgainstGitHub() async throws {
        let release = try await latest("relative", .redirect("/owner/relative/releases/tag/0.3"))
        #expect(release.version == AppVersion("0.3"))
        #expect(release.page.absoluteString == "https://github.com/owner/relative/releases/tag/0.3")
    }

    @Test func noReleaseYet() async {
        // GitHub sends a repository without releases to its releases list.
        await #expect(throws: ReleaseError.noRelease) {
            try await latest("empty", .redirect("https://github.com/owner/empty/releases"))
        }
        await #expect(throws: ReleaseError.noRelease) {
            try await latest("missing", .status(404, [:]))
        }
    }

    @Test(arguments: [200, 403, 429, 500, 503])
    func otherStatusesAreRefusals(_ status: Int) async {
        await #expect(throws: ReleaseError.refused(status: status)) {
            try await latest("status-\(status)", .status(status, [:]))
        }
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .networkConnectionLost, .secureConnectionFailed])
    func noNetworkIsUnreachable(_ code: URLError.Code) async {
        await #expect(throws: ReleaseError.unreachable) {
            try await latest("offline-\(code.rawValue)", .failure(code))
        }
    }

    @Test(arguments: [
        ("nightly", "https://github.com/owner/x/releases/tag/nightly"),
        ("beta", "https://github.com/owner/x/releases/tag/v0.2.0-beta"),
        ("http", "http://github.com/owner/x/releases/tag/v0.2.0"),
        ("login", "https://github.com/login?return_to=x"),
        ("root", "https://github.com/"),
    ])
    func redirectsThatAreNotAReleaseAreUnreadable(_ name: String, _ location: String) async {
        await #expect(throws: ReleaseError.unreadable) {
            try await latest("odd-\(name)", .redirect(location))
        }
    }

    @Test func aRedirectWithNowhereToGoIsUnreadable() async {
        await #expect(throws: ReleaseError.unreadable) {
            try await latest("nowhere", .status(302, [:]))
        }
    }

    @Test func theAddressIsTheRepositorysLatestReleasePage() {
        #expect(GitHubReleases(repository: "Glimmer-X/Nibble").url.absoluteString == "https://github.com/Glimmer-X/Nibble/releases/latest")
    }

    /// Against GitHub itself: the redirect is read, not followed (followed, the tag page would
    /// answer 200, a refusal).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NIBBLE_NETWORK_TESTS"] == "1"))
    func nibblesOwnLatestReleaseOnGitHub() async throws {
        let release = try await GitHubReleases(repository: "Glimmer-X/Nibble").latest()
        #expect(release.version >= AppVersion("0.1.1")!)
        #expect(release.page.absoluteString.hasPrefix("https://github.com/Glimmer-X/Nibble/releases/tag/"))
    }
}
