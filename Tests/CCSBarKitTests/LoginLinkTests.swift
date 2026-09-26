import XCTest
@testable import CCSBarKit

/// The sign-in link the login banner offers when the browser opened out of
/// sight (2026-09-26: `open` handed the codex PKCE page to an agent's headless
/// Chrome, and the user had no way to reach it).
final class LoginLinkTests: XCTestCase {
    private let authorize =
        "https://auth.openai.com/oauth/authorize?response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=abc"

    func testTheCodexAnnouncementYieldsItsURL() {
        let url = DaemonClient.loginLink(fromLine: "clauth: opening \(authorize)\n")
        XCTAssertEqual(url?.absoluteString, authorize)
    }

    func testOtherLinesAndNonHttpsAreNotALink() {
        XCTAssertNil(DaemonClient.loginLink(
            fromLine: "clauth: if the browser did not open, paste that URL into it"))
        XCTAssertNil(DaemonClient.loginLink(fromLine: authorize))
        XCTAssertNil(DaemonClient.loginLink(fromLine: "clauth: opening http://example.com/x"))
        XCTAssertNil(DaemonClient.loginLink(fromLine: "clauth: opening file:///etc/passwd"))
    }

    /// Pipe reads split lines anywhere; the URL still comes out whole, once.
    func testChunkedOutputReportsTheLinkOnce() {
        let scan = DaemonClient.LinkScan()
        let text = "clauth: opening \(authorize)\nclauth: if the browser did not open\n"
        let bytes = Array(text.utf8)
        var found: [URL] = []
        var i = 0
        while i < bytes.count {
            let end = min(i + 17, bytes.count)
            if let url = scan.feed(Data(bytes[i..<end])) { found.append(url) }
            i = end
        }
        XCTAssertEqual(found.map(\.absoluteString), [authorize])
        XCTAssertNil(scan.feed(Data("clauth: opening \(authorize)\n".utf8)))
    }

    func testTheBannerKeepsTheLinkOnItsFlight() {
        var flight = LoginFlight(name: "ax-codex-xfx", mode: .browser)
        XCTAssertNil(flight.link)
        flight.link = URL(string: authorize)
        XCTAssertEqual(flight.bannerText, "Signing in to ax-codex-xfx — finish in your browser…")
        XCTAssertEqual(flight.link?.absoluteString, authorize)
    }
}
