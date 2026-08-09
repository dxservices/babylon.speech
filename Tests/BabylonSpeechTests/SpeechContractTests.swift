import BabylonAudio
import Foundation
import Testing
@testable import BabylonSpeech

@Suite("Speech contracts")
struct SpeechContractTests {
    @Test("Speech identity is bound to an audio flow")
    func sessionIdentityBindsAudioFlow() {
        let rawValue = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let firstFlow = AudioFlowID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        let secondFlow = AudioFlowID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        )
        let first = SpeechSessionID(rawValue: rawValue, audioFlowID: firstFlow)
        let replacement = SpeechSessionID(rawValue: rawValue, audioFlowID: secondFlow)

        #expect(first != replacement)
        #expect(first.accepts(audioFlowID: firstFlow))
        #expect(!first.accepts(audioFlowID: secondFlow))
        requireSendable(first)
    }

    @Test("Text delta and completion have distinct semantics")
    func textDeltaAndCompletionAreDistinct() throws {
        let segmentID = SpeechSegmentID(rawValue: 4)
        let language = try SpeechLanguageTag("en-US")
        let delta = SpeechTextEvent.delta(
            .init(segmentID: segmentID, text: "hel", language: language)
        )
        let completed = SpeechTextEvent.completed(
            .init(segmentID: segmentID, text: "hello", language: language)
        )

        #expect(delta.segmentID == segmentID)
        #expect(delta.text == "hel")
        #expect(!delta.isCompleted)
        #expect(completed.text == "hello")
        #expect(completed.isCompleted)
        requireSendable(delta)
        requireSendable(completed)
    }

    @Test("Translation requires a target language")
    func translationRequiresTargetLanguage() throws {
        let sessionID = SpeechSessionID(audioFlowID: AudioFlowID())

        #expect(throws: SpeechContractError.targetLanguageRequired) {
            try SpeechSessionConfiguration(
                sessionID: sessionID,
                features: [.translation],
                sourceLanguage: .automatic
            )
        }
        #expect(throws: SpeechContractError.targetLanguageNotUsed) {
            try SpeechSessionConfiguration(
                sessionID: sessionID,
                features: [.transcription],
                sourceLanguage: .automatic,
                targetLanguage: SpeechLanguageTag("zh")
            )
        }
    }

    @Test("Session configuration supports transcription and translation together")
    func sessionConfigurationSupportsBothTextFeatures() throws {
        let sourceLanguage = try SpeechLanguageTag("en")
        let targetLanguage = try SpeechLanguageTag("zh-Hant")
        let configuration = try SpeechSessionConfiguration(
            sessionID: SpeechSessionID(audioFlowID: AudioFlowID()),
            features: [.transcription, .translation],
            sourceLanguage: .language(sourceLanguage),
            targetLanguage: targetLanguage
        )

        #expect(configuration.features == [.transcription, .translation])
        #expect(configuration.sourceLanguage == .language(sourceLanguage))
        #expect(configuration.targetLanguage == targetLanguage)
        requireSendable(configuration)
    }

    @Test("Failure exposes classification and validated identifiers only")
    func failureIsStructuredAndSafe() throws {
        let failure = SpeechProviderFailure(
            classification: .sessionExpired,
            type: try SpeechFailureIdentifier("invalid_request_error"),
            code: try SpeechFailureIdentifier("session_expired")
        )

        #expect(failure.type.value == "invalid_request_error")
        #expect(failure.code?.value == "session_expired")
        #expect(throws: SpeechContractError.invalidFailureIdentifier) {
            try SpeechFailureIdentifier("full error body must not pass")
        }
        requireSendable(failure)
    }

    @Test("Capabilities can reject unsupported session requirements")
    func capabilitiesEvaluateConfigurations() throws {
        let inputFormat = try AudioStreamFormat.monoPCM16(sampleRate: 16_000)
        let capabilities = SpeechProviderCapabilities(
            requiresNetwork: false,
            credentialRequirement: .none,
            supportedFeatures: [.transcription],
            acceptedInputFormats: [inputFormat],
            outputAudioFormats: [],
            supportsAutomaticSourceLanguage: false,
            reportsDetectedSourceLanguage: true
        )
        let automatic = try SpeechSessionConfiguration(
            sessionID: SpeechSessionID(audioFlowID: AudioFlowID()),
            features: [.transcription],
            sourceLanguage: .automatic
        )
        let explicit = try SpeechSessionConfiguration(
            sessionID: SpeechSessionID(audioFlowID: AudioFlowID()),
            features: [.transcription],
            sourceLanguage: .language(SpeechLanguageTag("en"))
        )

        #expect(!capabilities.supports(automatic))
        #expect(capabilities.supports(explicit))
        #expect(!capabilities.requiresCredential)
        requireSendable(capabilities)
    }
}

private func requireSendable<T: Sendable>(_: T) {}
