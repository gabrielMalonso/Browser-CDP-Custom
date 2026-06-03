import XCTest
@testable import CustomCDPBrowser

final class CustomCDPBrowserTests: XCTestCase {
    func testInvalidLinkRoutingModeFallsBackToAskEveryTime() {
        XCTAssertEqual(LinkRoutingMode(storedValue: "unknown"), .askEveryTime)
        XCTAssertEqual(LinkRoutingMode(storedValue: nil), .askEveryTime)
    }

    func testVisibleProfilesContainExpectedProfilesInOrder() {
        XCTAssertEqual(
            CDPProfile.visibleProfiles.map(\.id),
            [
                "pessoal",
                "central-es",
                "central-rj",
                "central-sp",
                "financeiro-rossoni",
            ]
        )
    }

    func testPessoalIsDefaultProfile() {
        XCTAssertEqual(CDPProfile.defaultProfile.id, "pessoal")
        XCTAssertEqual(CDPProfile.visibleProfiles.first?.id, "pessoal")
    }

    func testProfileLookupFallsBackToPessoalForInvalidID() {
        XCTAssertEqual(CDPProfile.profile(withID: "central-rj").id, "central-rj")
        XCTAssertEqual(CDPProfile.profile(withID: "missing").id, "pessoal")
        XCTAssertEqual(CDPProfile.profile(withID: nil).id, "pessoal")
    }

    @MainActor
    func testNewTabEndpointPreservesQueryAndFragment() {
        let url = URL(string: "https://example.com/path?q=one%20two&next=/x#section")!
        let endpoint = CDPProfileLauncher.newTabEndpoint(for: url, port: 9224)
        let encodedURL = endpoint.absoluteString.split(separator: "?", maxSplits: 1).last.map(String.init)

        XCTAssertEqual(endpoint.scheme, "http")
        XCTAssertEqual(endpoint.host, "127.0.0.1")
        XCTAssertEqual(endpoint.port, 9224)
        XCTAssertEqual(endpoint.path, "/json/new")
        XCTAssertEqual(encodedURL?.removingPercentEncoding, url.absoluteString)
    }

    @MainActor
    func testRoutingDecisionUsesConfiguredMode() {
        XCTAssertEqual(
            LinkRouter.routingDecision(mode: .askEveryTime, lastSelectedProfileID: "central-rj"),
            .ask
        )
        XCTAssertEqual(
            LinkRouter.routingDecision(mode: .personal, lastSelectedProfileID: "central-rj"),
            .route(CDPProfile.defaultProfile)
        )
        XCTAssertEqual(
            LinkRouter.routingDecision(mode: .lastSelected, lastSelectedProfileID: "central-rj"),
            .route(CDPProfile.profile(withID: "central-rj"))
        )
        XCTAssertEqual(
            LinkRouter.routingDecision(mode: .lastSelected, lastSelectedProfileID: "missing"),
            .route(CDPProfile.defaultProfile)
        )
    }

    @MainActor
    func testAskEveryTimeEnqueuesIncomingURL() {
        let defaults = UserDefaults(suiteName: "CustomCDPBrowserTests-\(UUID().uuidString)")!
        defaults.set(LinkRoutingMode.askEveryTime.rawValue, forKey: UserDefaultsKeys.linkRoutingMode)

        let router = LinkRouter(userDefaults: defaults)
        let url = URL(string: "https://example.com/a?b=c#d")!

        router.handleIncomingURL(url)

        XCTAssertEqual(router.pendingURLs, [url])
    }
}
