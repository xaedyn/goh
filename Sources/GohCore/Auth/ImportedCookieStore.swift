import Foundation
import Synchronization

public final class ImportedCookieStore: Sendable {
    private struct State {
        var jar: SafariCookieJar
        var jobHeaders: [UInt64: String]
    }

    private let state: Mutex<State>

    public init(cookies: [SafariCookie] = []) {
        self.state = Mutex(State(
            jar: SafariCookieJar(cookies: cookies),
            jobHeaders: [:]))
    }

    public func replaceCookies(_ cookies: [SafariCookie]) {
        state.withLock { state in
            state.jar = SafariCookieJar(cookies: cookies)
        }
    }

    @discardableResult
    public func snapshotHeader(forJobID jobID: UInt64, url: URL, now: Date = Date()) -> String? {
        state.withLock { state in
            let header = state.jar.cookieHeader(for: url, now: now)
            state.jobHeaders[jobID] = header
            return header
        }
    }

    public func header(forJobID jobID: UInt64) -> String? {
        state.withLock { $0.jobHeaders[jobID] }
    }

    public func removeHeader(forJobID jobID: UInt64) {
        state.withLock { state in
            state.jobHeaders[jobID] = nil
        }
    }
}
