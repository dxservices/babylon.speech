import Foundation
import XCTest
@testable import BabylonSpeechOpenAI

final class OpenAIRealtimeAuthorizationTests: XCTestCase {
    func testAuthorizationAppliesBearerHeaderWithoutDescribingSecret() {
        let secret = "short-lived-private-secret"
        let authorization = OpenAIRealtimeAuthorization(
            clientSecret: secret
        )
        var request = URLRequest(url: URL(string: "wss://example.com")!)

        XCTAssertTrue(authorization.apply(to: &request))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(secret)"
        )
        XCTAssertFalse(String(describing: authorization).contains(secret))
        XCTAssertFalse(String(reflecting: authorization).contains(secret))
        requireSendable(authorization)
    }

    func testEmptyAuthorizationDoesNotCreateBearerHeader() {
        let authorization = OpenAIRealtimeAuthorization(clientSecret: "")
        var request = URLRequest(url: URL(string: "wss://example.com")!)

        XCTAssertFalse(authorization.apply(to: &request))
        XCTAssertNil(
            request.value(forHTTPHeaderField: "Authorization")
        )
    }
}

private func requireSendable<T: Sendable>(_: T) {}
