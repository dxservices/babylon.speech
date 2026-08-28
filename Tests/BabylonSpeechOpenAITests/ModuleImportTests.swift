import BabylonSpeech
import BabylonSpeechOpenAI
import XCTest

@available(iOS 18, macOS 15, *)
@MainActor
final class ModuleImportTests: XCTestCase {
    func testPublicProviderSurfaceCompilesWithoutConnecting() {
        let authorization = OpenAIRealtimeAuthorization(
            clientSecret: "unit-test-client-secret"
        )
        let provider: any SpeechProvider = OpenAIRealtimeSpeechProvider(
            authorization: authorization
        )

        XCTAssertTrue(provider.capabilities.requiresNetwork)
        XCTAssertEqual(
            provider.capabilities.credentialRequirement,
            .callerInjected
        )
        XCTAssertEqual(provider.capabilities.requiredFeatures, [.translation])
    }
}
