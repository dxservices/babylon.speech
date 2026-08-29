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
        let observer: OpenAIRealtimeTransferObserver = { sessionID, fact in
            _ = sessionID
            _ = fact.direction
            _ = fact.applicationPayloadBytes
        }
        let audioObserver: OpenAIRealtimeAudioTransferObserver = {
            sessionID,
            fact in
            _ = sessionID
            _ = fact.direction
            _ = fact.audioDuration
        }
        let provider: any SpeechProvider = OpenAIRealtimeSpeechProvider(
            authorization: authorization,
            transferObserver: observer,
            audioTransferObserver: audioObserver
        )

        XCTAssertTrue(provider.capabilities.requiresNetwork)
        XCTAssertEqual(
            provider.capabilities.credentialRequirement,
            .callerInjected
        )
        XCTAssertEqual(provider.capabilities.requiredFeatures, [.translation])
        requireSendable(SpeechSessionStopMode.immediate)
        requireSendable(SpeechSessionStopOutcome.forced)
        requireSendable(OpenAIRealtimeTransferDirection.uplink)
        requireSendable(OpenAIRealtimeTransferDirection.downlink)
        requireSendableType(OpenAIRealtimeTransferFact.self)
        requireSendableType(OpenAIRealtimeAudioTransferFact.self)
        requireEquatableType(OpenAIRealtimeTransferDirection.self)
        requireEquatableType(OpenAIRealtimeTransferFact.self)
        requireEquatableType(OpenAIRealtimeAudioTransferFact.self)
    }
}

private func requireSendable<T: Sendable>(_: T) {}
private func requireSendableType<T: Sendable>(_: T.Type) {}
private func requireEquatableType<T: Equatable>(_: T.Type) {}
