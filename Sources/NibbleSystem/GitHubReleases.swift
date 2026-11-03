import Foundation
import NibbleCore

/// The latest release of a GitHub repository, read from where its release page points:
/// `github.com/OWNER/REPO/releases/latest` redirects to the newest release's tag page (drafts and
/// pre-releases skipped), and that tag is the version. The redirect itself is the answer, so
/// nothing else is downloaded.
///
/// The page rather than GitHub's API: the API allows 60 requests an hour without a token, counted
/// per address and so shared by everyone behind one (an office, a campus, a VPN), and is often used
/// up there. The request carries nothing about the reader: no cookies, no identifier.
public struct GitHubReleases: ReleaseSource {
    public let url: URL
    private let session: URLSession

    /// `repository` is "owner/name".
    public init(repository: String, session: URLSession = GitHubReleases.session) {
        self.url = URL(string: "https://github.com/\(repository)/releases/latest")!
        self.session = session
    }

    /// No cache, no cookies; waits up to a minute for a network (a check right after login).
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    public func latest() async throws -> Release {
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: URLRequest(url: url), delegate: StayPut())
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ReleaseError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw ReleaseError.unreadable }
        switch http.statusCode {
        case 301, 302, 303, 307, 308:
            guard let location = http.value(forHTTPHeaderField: "Location"),
                  let page = URL(string: location, relativeTo: url)?.absoluteURL
            else { throw ReleaseError.unreadable }
            return try Self.release(at: page)
        case 404:
            throw ReleaseError.noRelease
        default:
            throw ReleaseError.refused(status: http.statusCode)
        }
    }

    /// The release a tag page stands for: `…/releases/tag/v0.1.2` is 0.1.2. A repository without
    /// releases points at its releases list instead.
    static func release(at page: URL) throws -> Release {
        let parts = page.pathComponents
        guard page.scheme == "https", parts.count >= 3, parts[parts.count - 2] == "tag" else {
            throw parts.last == "releases" ? ReleaseError.noRelease : ReleaseError.unreadable
        }
        guard let version = AppVersion(parts[parts.count - 1]) else { throw ReleaseError.unreadable }
        return Release(version: version, page: page)
    }
}

/// Keeps a request where it is: the redirect is the answer, not the page it leads to.
private final class StayPut: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
