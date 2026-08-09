import BabylonAudio
import Foundation
import Testing
@testable import BabylonSpeech

@Suite("Speech provider contract fakes")
struct SpeechProviderContractTests {
    @Test("A 24 kHz cloud-shaped fake uses the neutral contract")
    func openAIShapedFake() async throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let provider = ContractFakeProvider(
            capabilities: .cloud(
                inputFormat: format,
                outputFormat: format,
                credentialRequirement: .callerInjected
            )
        )

        #expect(provider.capabilities.acceptedInputFormats == [format])
        #expect(provider.capabilities.outputAudioFormats == [format])
        try await verifySharedContract(provider: provider, inputFormat: format)
    }

    @Test("A split-rate cloud-shaped fake uses the neutral contract")
    func googleShapedFake() async throws {
        let inputFormat = try AudioStreamFormat.monoPCM16(sampleRate: 16_000)
        let outputFormat = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let provider = ContractFakeProvider(
            capabilities: .cloud(
                inputFormat: inputFormat,
                outputFormat: outputFormat,
                credentialRequirement: .callerInjected
            )
        )

        #expect(provider.capabilities.acceptedInputFormats == [inputFormat])
        #expect(provider.capabilities.outputAudioFormats == [outputFormat])
        try await verifySharedContract(provider: provider, inputFormat: inputFormat)
    }

    @Test("An in-process model fake needs neither network nor credentials")
    func localModelShapedFake() async throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 16_000)
        let capabilities = SpeechProviderCapabilities(
            requiresNetwork: false,
            credentialRequirement: .none,
            supportedFeatures: [.transcription, .translation],
            acceptedInputFormats: [format],
            outputAudioFormats: [],
            supportsAutomaticSourceLanguage: false,
            reportsDetectedSourceLanguage: true
        )
        let provider = ContractFakeProvider(capabilities: capabilities)

        #expect(!provider.capabilities.requiresNetwork)
        #expect(!provider.capabilities.requiresCredential)
        try await verifySharedContract(provider: provider, inputFormat: format)
    }

    private func verifySharedContract(
        provider: any SpeechProvider,
        inputFormat: AudioStreamFormat
    ) async throws {
        let flowID = AudioFlowID()
        let sessionID = SpeechSessionID(audioFlowID: flowID)
        let sourceLanguage: SpeechLanguagePreference = provider.capabilities
            .supportsAutomaticSourceLanguage
            ? .automatic
            : .language(try SpeechLanguageTag("en"))
        let configuration = try SpeechSessionConfiguration(
            sessionID: sessionID,
            features: [.transcription, .translation],
            sourceLanguage: sourceLanguage,
            targetLanguage: SpeechLanguageTag("zh")
        )

        #expect(provider.capabilities.supports(configuration))
        #expect(provider.capabilities.accepts(inputFormat: inputFormat))
        let stream = try await provider.startSession(configuration)
        let frame = try AudioFrame(
            flowID: flowID,
            sequence: 0,
            timestamp: .zero,
            format: inputFormat,
            payload: Data(count: Int(inputFormat.sampleRate / 50) * inputFormat.bytesPerFrame),
            duration: .milliseconds(20)
        )

        try await provider.consume(frame, for: sessionID)
        await provider.stopSession(sessionID)

        var events: [SpeechEvent] = []
        for await event in stream {
            events.append(event)
        }

        #expect(events == ContractFakeProvider.expectedEvents(for: sessionID))
        #expect(events.allSatisfy { $0.sessionID == sessionID })

        do {
            try await provider.consume(frame, for: sessionID)
            Issue.record("A stopped session accepted a late frame")
        } catch {
            #expect(error.classification == .invalidSession)
        }
    }

    @Test("A frame from another flow is rejected structurally")
    func staleFlowIsRejected() async throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let provider = ContractFakeProvider(
            capabilities: .cloud(
                inputFormat: format,
                outputFormat: format,
                credentialRequirement: .callerInjected
            )
        )
        let sessionID = SpeechSessionID(audioFlowID: AudioFlowID())
        let configuration = try SpeechSessionConfiguration(
            sessionID: sessionID,
            features: [.transcription],
            sourceLanguage: .automatic
        )
        _ = try await provider.startSession(configuration)
        let staleFrame = try AudioFrame(
            flowID: AudioFlowID(),
            sequence: 0,
            timestamp: .zero,
            format: format,
            payload: Data(count: 960),
            duration: .milliseconds(20)
        )

        await #expect(throws: SpeechProviderFailure.self) {
            try await provider.consume(staleFrame, for: sessionID)
        }
    }
}

private actor ContractFakeProvider: SpeechProvider {
    nonisolated let capabilities: SpeechProviderCapabilities
    private var activeSessions: Set<SpeechSessionID> = []
    private var continuations: [SpeechSessionID: AsyncStream<SpeechEvent>.Continuation] = [:]

    init(capabilities: SpeechProviderCapabilities) {
        self.capabilities = capabilities
    }

    func startSession(
        _ configuration: SpeechSessionConfiguration
    ) async throws(SpeechProviderFailure) -> AsyncStream<SpeechEvent> {
        activeSessions.insert(configuration.sessionID)
        let (stream, continuation) = AsyncStream<SpeechEvent>.makeStream()
        continuations[configuration.sessionID] = continuation
        continuation.yield(.sessionStarted(sessionID: configuration.sessionID))
        return stream
    }

    func consume(
        _ frame: AudioFrame,
        for sessionID: SpeechSessionID
    ) async throws(SpeechProviderFailure) {
        guard activeSessions.contains(sessionID), sessionID.accepts(frame: frame) else {
            throw SpeechProviderFailure(
                classification: .invalidSession,
                type: try! SpeechFailureIdentifier("flow_mismatch"),
                code: nil
            )
        }

        for event in Self.textEvents(for: sessionID) {
            continuations[sessionID]?.yield(event)
        }
    }

    func stopSession(_ sessionID: SpeechSessionID) async {
        continuations[sessionID]?.yield(.sessionEnded(
            sessionID: sessionID,
            reason: .consumerRequested
        ))
        continuations.removeValue(forKey: sessionID)?.finish()
        activeSessions.remove(sessionID)
    }

    nonisolated static func expectedEvents(for sessionID: SpeechSessionID) -> [SpeechEvent] {
        [.sessionStarted(sessionID: sessionID)]
            + textEvents(for: sessionID)
            + [.sessionEnded(sessionID: sessionID, reason: .consumerRequested)]
    }

    nonisolated private static func textEvents(for sessionID: SpeechSessionID) -> [SpeechEvent] {
        let segmentID = SpeechSegmentID(rawValue: 1)
        return [
            .transcription(
                sessionID: sessionID,
                text: .delta(.init(segmentID: segmentID, text: "hel", language: nil))
            ),
            .transcription(
                sessionID: sessionID,
                text: .completed(.init(segmentID: segmentID, text: "hello", language: nil))
            ),
            .translation(
                sessionID: sessionID,
                text: .delta(.init(segmentID: segmentID, text: "ni", language: nil))
            ),
            .translation(
                sessionID: sessionID,
                text: .completed(.init(segmentID: segmentID, text: "ni hao", language: nil))
            ),
        ]
    }
}

private extension SpeechProviderCapabilities {
    static func cloud(
        inputFormat: AudioStreamFormat,
        outputFormat: AudioStreamFormat,
        credentialRequirement: SpeechCredentialRequirement
    ) -> Self {
        Self(
            requiresNetwork: true,
            credentialRequirement: credentialRequirement,
            supportedFeatures: [.transcription, .translation],
            acceptedInputFormats: [inputFormat],
            outputAudioFormats: [outputFormat],
            supportsAutomaticSourceLanguage: true,
            reportsDetectedSourceLanguage: false
        )
    }
}
