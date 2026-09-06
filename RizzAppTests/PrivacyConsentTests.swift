import XCTest
@testable import RizzApp

final class PrivacyConsentTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PrivacyConsentStore().reset()
    }

    func testStartsUnacknowledged() {
        XCTAssertFalse(PrivacyConsentStore().hasAcknowledged)
    }

    func testAcknowledgePersists() {
        let store = PrivacyConsentStore()
        store.acknowledge()
        XCTAssertTrue(PrivacyConsentStore().hasAcknowledged)
    }

    func testLegalLinksAreFlaggedAsPlaceholders() {
        // Fails (on purpose) the day someone ships example.com URLs
        // without noticing — flip LegalLinks and this assertion together.
        XCTAssertTrue(LegalLinks.arePlaceholders)
        XCTAssertTrue(LegalLinks.privacy.absoluteString.contains("example.com"))
    }
}
