import XCTest
@testable import RizzApp

final class SubscriptionServiceTests: XCTestCase {
    func testMockOfferingsHaveMonthlyAndYearly() async throws {
        let service = MockSubscriptionService()
        let plans = try await service.offerings()
        XCTAssertEqual(plans.map(\.period), ["month", "year"])
        XCTAssertFalse(service.isPremium)
    }

    func testMockPurchaseIsNotFakeSuccess() async {
        let service = MockSubscriptionService()
        do {
            _ = try await service.purchase(
                SubscriptionPlan(id: "$rc_monthly", name: "Monthly", price: "$6.99", period: "month", detail: nil)
            )
            XCTFail("Mock must not fake a successful purchase")
        } catch SubscriptionError.notConfigured {
            XCTAssertFalse(service.isPremium)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testMockCanStartInPremiumStateForUIPreview() {
        let service = MockSubscriptionService(startPremium: true)
        XCTAssertTrue(service.isPremium)
        XCTAssertEqual(service.status.planName, "Yearly")
        XCTAssertTrue(service.status.willRenew)
    }

    func testSubscriptionErrorCopyIsNonTechnical() {
        XCTAssertFalse(SubscriptionError.purchaseFailed.displayMessage.contains("RevenueCat"))
        XCTAssertFalse(SubscriptionError.offeringsUnavailable.displayMessage.contains("StoreKit"))
    }
}
