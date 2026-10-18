import XCTest
@testable import RizzApp

final class RevenueCatIdentityBindingTests: XCTestCase {
    private let userA = AuthenticatedUser(
        id: "11111111-2222-4333-8444-555555555555",
        accessToken: "token-a"
    )
    private let userB = AuthenticatedUser(
        id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        accessToken: "token-b"
    )

    func testFirstSuccessfulAuthenticationBindsUser() {
        var binding = RevenueCatIdentityBinding()
        let transition = binding.beginAuthentication(for: userA.id)
        XCTAssertEqual(transition, 1)
        XCTAssertNil(binding.authenticatedUserID)
        XCTAssertTrue(binding.succeed(userID: userA.id, transition: 1))
        XCTAssertEqual(binding.authenticatedUserID, userA.id)
    }

    func testReturningSameUserDoesNotStartANewLogin() {
        var binding = RevenueCatIdentityBinding()
        _ = binding.beginAuthentication(for: userA.id)
        _ = binding.succeed(userID: userA.id, transition: 1)
        XCTAssertNil(binding.beginAuthentication(for: userA.id))
        XCTAssertEqual(binding.authenticatedUserID, userA.id)
    }

    func testSwitchingFromUserAToUserBInvalidatesA() {
        var binding = RevenueCatIdentityBinding()
        _ = binding.beginAuthentication(for: userA.id)
        _ = binding.succeed(userID: userA.id, transition: 1)

        let transition = binding.beginAuthentication(for: userB.id)
        XCTAssertEqual(transition, 2)
        XCTAssertNil(binding.authenticatedUserID)
        XCTAssertTrue(binding.succeed(userID: userB.id, transition: 2))
        XCTAssertEqual(binding.authenticatedUserID, userB.id)
    }

    func testFailedAuthenticationForUserBDoesNotKeepUserA() {
        var binding = RevenueCatIdentityBinding()
        _ = binding.beginAuthentication(for: userA.id)
        _ = binding.succeed(userID: userA.id, transition: 1)

        let transition = binding.beginAuthentication(for: userB.id)
        XCTAssertNil(binding.authenticatedUserID)
        binding.fail(transition: transition!)
        XCTAssertNil(binding.authenticatedUserID)
        XCTAssertFalse(binding.succeed(userID: userB.id, transition: transition!))
    }

    func testStaleSuccessAfterIdentityChangeIsRejected() {
        var binding = RevenueCatIdentityBinding()
        let first = binding.beginAuthentication(for: userA.id)!
        let second = binding.beginAuthentication(for: userB.id)!
        XCTAssertFalse(binding.succeed(userID: userA.id, transition: first))
        XCTAssertTrue(binding.succeed(userID: userB.id, transition: second))
        XCTAssertEqual(binding.authenticatedUserID, userB.id)
    }
}

final class RevenueCatIdentitySynchronizerTests: XCTestCase {
    private let userA = AuthenticatedUser(
        id: "11111111-2222-4333-8444-555555555555",
        accessToken: "token-a"
    )
    private let userB = AuthenticatedUser(
        id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        accessToken: "token-b"
    )

    func testFirstSuccessfulAuthentication() async throws {
        let logins = LoginRecorder()
        let sync = RevenueCatIdentitySynchronizer { user in
            await logins.append(user.id)
        }

        let didLogIn = try await sync.authenticate(userA)

        XCTAssertTrue(didLogIn)
        XCTAssertEqual(await sync.authenticatedUserID, userA.id)
        XCTAssertEqual(await logins.ids, [userA.id])
    }

    func testReturningSameUserSkipsRevenueCatLogin() async throws {
        let logins = LoginRecorder()
        let sync = RevenueCatIdentitySynchronizer { user in
            await logins.append(user.id)
        }

        _ = try await sync.authenticate(userA)
        let didLogInAgain = try await sync.authenticate(userA)

        XCTAssertFalse(didLogInAgain)
        XCTAssertEqual(await logins.ids, [userA.id])
        XCTAssertEqual(await sync.authenticatedUserID, userA.id)
    }

    func testSwitchingFromUserAToUserBRequiresANewLogin() async throws {
        let logins = LoginRecorder()
        let sync = RevenueCatIdentitySynchronizer { user in
            await logins.append(user.id)
        }

        _ = try await sync.authenticate(userA)
        let didLogInB = try await sync.authenticate(userB)

        XCTAssertTrue(didLogInB)
        XCTAssertEqual(await sync.authenticatedUserID, userB.id)
        XCTAssertEqual(await logins.ids, [userA.id, userB.id])
    }

    func testFailedRevenueCatAuthenticationForUserBClearsBinding() async {
        let sync = RevenueCatIdentitySynchronizer { user in
            if user.id.hasPrefix("aaaaaaaa") {
                throw URLError(.notConnectedToInternet)
            }
        }

        do {
            _ = try await sync.authenticate(userA)
        } catch {
            XCTFail("user A should authenticate")
        }

        do {
            _ = try await sync.authenticate(userB)
            XCTFail("user B login should fail")
        } catch SubscriptionError.verificationUnavailable {
            XCTAssertNil(await sync.authenticatedUserID)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testInterruptedTransitionDoesNotKeepThePreviousUser() async {
        let sync = RevenueCatIdentitySynchronizer { _ in
            throw URLError(.timedOut)
        }

        do {
            _ = try await sync.authenticate(userA)
            XCTFail("expected failure")
        } catch SubscriptionError.verificationUnavailable {
            XCTAssertNil(await sync.authenticatedUserID)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testOlderAsyncSuccessAfterIdentityChangeDoesNotRestorePreviousUser() async throws {
        let gate = LoginGate()
        let sync = RevenueCatIdentitySynchronizer { user in
            if user.id.hasPrefix("11111111") {
                try await gate.waitForFirst()
            }
        }

        let first = Task {
            try await sync.authenticate(self.userA)
        }
        await gate.waitUntilStarted()

        _ = try await sync.authenticate(userB)
        XCTAssertEqual(await sync.authenticatedUserID, userB.id)

        await gate.releaseFirst()
        do {
            _ = try await first.value
            XCTFail("stale user A login must not succeed")
        } catch SubscriptionError.verificationUnavailable {
            XCTAssertEqual(await sync.authenticatedUserID, userB.id)
        }
    }
}

private actor LoginRecorder {
    var ids: [String] = []
    func append(_ id: String) { ids.append(id) }
}

private actor LoginGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Error>?

    func waitForFirst() async throws {
        started = true
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        for _ in 0..<200 {
            if started { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func releaseFirst() {
        continuation?.resume()
        continuation = nil
    }
}
