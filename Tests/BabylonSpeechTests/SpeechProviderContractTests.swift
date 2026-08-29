import BabylonAudio
import Foundation
import Testing
@testable import BabylonSpeech

@Suite("Speech provider session channels")
struct SpeechProviderContractTests {
    @Test("Stop modes dispatch through the provider existential")
    func stopModesDispatchThroughExistential() async throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let implementation = ContractFakeProvider(
            capabilities: .cloud(inputFormat: format, outputFormat: format),
            downlinkFormat: format
        )
        let provider: any SpeechProvider = implementation
        let configuration = try makeConfiguration(flowID: AudioFlowID())
        _ = try await provider.startSession(configuration)

        let outcome = await provider.stopSession(
            configuration.sessionID,
            mode: .immediate
        )

        #expect(outcome == .immediate)
        #expect(await implementation.stopModes == [.immediate])
        #expect(
            await provider.stopSession(
                configuration.sessionID,
                mode: .graceful
            ) == .noMatchingSession
        )
    }

    @Test("The legacy stop overload remains a graceful Void convenience")
    func legacyStopRemainsGracefulVoidConvenience() async throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let implementation = ContractFakeProvider(
            capabilities: .cloud(inputFormat: format, outputFormat: format),
            downlinkFormat: format
        )
        let provider: any SpeechProvider = implementation
        let configuration = try makeConfiguration(flowID: AudioFlowID())
        _ = try await provider.startSession(configuration)

        let result: Void = await provider.stopSession(configuration.sessionID)

        #expect(result == ())
        #expect(await implementation.stopModes == [.graceful])
    }

    @Test("Stop mode and outcome values are Sendable")
    func stopValuesAreSendable() {
        requireSendable(SpeechSessionStopMode.graceful)
        requireSendable(SpeechSessionStopMode.immediate)
        requireSendable(SpeechSessionStopOutcome.noMatchingSession)
        requireSendable(SpeechSessionStopOutcome.graceful)
        requireSendable(SpeechSessionStopOutcome.immediate)
        requireSendable(SpeechSessionStopOutcome.forced)
        requireSendable(SpeechSessionStopOutcome.failed)
    }

    @Test("A 24 kHz cloud-shaped provider exposes uplink and downlink through the existential")
    func openAIShapedChannels() async throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let provider: any SpeechProvider = ContractFakeProvider(
            capabilities: .cloud(inputFormat: format, outputFormat: format),
            downlinkFormat: format
        )

        try await verifyDuplexChannels(
            provider: provider,
            inputFormat: format,
            outputFormat: format
        )
    }

    @Test("A split-rate cloud-shaped provider exposes 16 kHz uplink and 24 kHz downlink")
    func googleShapedChannels() async throws {
        let inputFormat = try AudioStreamFormat.monoPCM16(sampleRate: 16_000)
        let outputFormat = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let provider: any SpeechProvider = ContractFakeProvider(
            capabilities: .cloud(inputFormat: inputFormat, outputFormat: outputFormat),
            downlinkFormat: outputFormat
        )

        try await verifyDuplexChannels(
            provider: provider,
            inputFormat: inputFormat,
            outputFormat: outputFormat
        )
    }

    @Test("An in-process transcription provider has no downlink")
    func localModelShapedChannels() async throws {
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
        let provider: any SpeechProvider = ContractFakeProvider(
            capabilities: capabilities,
            downlinkFormat: nil
        )
        let configuration = try makeConfiguration(
            flowID: AudioFlowID(),
            features: [.transcription],
            automaticLanguage: false
        )

        let channels = try await provider.startSession(configuration)
        #expect(channels.sessionID == configuration.sessionID)
        #expect(channels.downlink == nil)

        let frame = try makeFrame(
            flowID: configuration.sessionID.audioFlowID,
            format: inputFormat,
            marker: 0x21
        )
        try await channels.uplink.send(frame)
        await provider.stopSession(configuration.sessionID)

        let events = await collect(channels.events)
        #expect(events.contains { event in
            if case .transcription = event { return true }
            return false
        })
        #expect(events.allSatisfy { $0.sessionID == configuration.sessionID })
    }

    @Test("The session handle rejects uplink frames from another flow")
    func uplinkRejectsStaleFlowBeforeProviderDelivery() async throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let implementation = ContractFakeProvider(
            capabilities: .cloud(inputFormat: format, outputFormat: format),
            downlinkFormat: format
        )
        let provider: any SpeechProvider = implementation
        let configuration = try makeConfiguration(flowID: AudioFlowID())
        let channels = try await provider.startSession(configuration)
        let staleFrame = try makeFrame(
            flowID: AudioFlowID(),
            format: format,
            marker: 0x31
        )

        await #expect(throws: SpeechAudioChannelError.flowMismatch) {
            try await channels.uplink.send(staleFrame)
        }
        #expect(await implementation.receivedFrameCount == 0)
        await provider.stopSession(configuration.sessionID)
    }

    @Test("Replacing a speech session isolates an old handle on the same audio flow")
    func replacementRejectsOldSessionHandle() async throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let implementation = ContractFakeProvider(
            capabilities: .cloud(inputFormat: format, outputFormat: format),
            downlinkFormat: format
        )
        let provider: any SpeechProvider = implementation
        let flowID = AudioFlowID()
        let oldConfiguration = try makeConfiguration(flowID: flowID)
        let oldChannels = try await provider.startSession(oldConfiguration)
        let oldDownlink = try #require(oldChannels.downlink)
        let oldDownlinkFrames = oldDownlink.frames(for: flowID)
        let replacementConfiguration = try makeConfiguration(flowID: flowID)
        let replacementChannels = try await provider.startSession(replacementConfiguration)
        let frame = try makeFrame(flowID: flowID, format: format, marker: 0x41)

        await #expect(throws: SpeechProviderFailure.self) {
            try await oldChannels.uplink.send(frame)
        }
        try await replacementChannels.uplink.send(frame)
        #expect(await implementation.receivedFrameCount == 1)

        #expect(try await collect(oldDownlinkFrames).isEmpty)
        #expect(await collect(oldChannels.events) == [
            .sessionStarted(sessionID: oldConfiguration.sessionID),
            .sessionEnded(sessionID: oldConfiguration.sessionID, reason: .replaced),
        ])
        await provider.stopSession(replacementConfiguration.sessionID)
    }

    @Test("The handle filters events belonging to another session")
    func handleFiltersStaleSessionEvents() async throws {
        let flowID = AudioFlowID()
        let sessionID = SpeechSessionID(audioFlowID: flowID)
        let staleSessionID = SpeechSessionID(audioFlowID: flowID)
        let (rawEvents, continuation) = AsyncStream<SpeechEvent>.makeStream()
        let channels = SpeechSessionChannels(
            sessionID: sessionID,
            events: rawEvents,
            uplink: RecordingSender(),
            downlink: nil
        )

        continuation.yield(.sessionStarted(sessionID: staleSessionID))
        continuation.yield(.sessionStarted(sessionID: sessionID))
        continuation.finish()

        #expect(await collect(channels.events) == [.sessionStarted(sessionID: sessionID)])
    }

    @Test("The downlink rejects a request for another flow")
    func downlinkRejectsStaleFlowRequest() async throws {
        let sessionID = SpeechSessionID(audioFlowID: AudioFlowID())
        let channels = SpeechSessionChannels(
            sessionID: sessionID,
            events: AsyncStream { $0.finish() },
            uplink: RecordingSender(),
            downlink: FixedReceiver(frames: [])
        )
        let downlink = try #require(channels.downlink)

        await #expect(throws: SpeechAudioChannelError.flowMismatch) {
            for try await _ in downlink.frames(for: AudioFlowID()) {}
        }
    }

    @Test("The downlink rejects a stale frame emitted by its implementation")
    func downlinkRejectsStaleEmittedFrame() async throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let sessionID = SpeechSessionID(audioFlowID: AudioFlowID())
        let staleFrame = try makeFrame(
            flowID: AudioFlowID(),
            format: format,
            marker: 0x71
        )
        let channels = SpeechSessionChannels(
            sessionID: sessionID,
            events: AsyncStream { $0.finish() },
            uplink: RecordingSender(),
            downlink: FixedReceiver(frames: [staleFrame])
        )
        let downlink = try #require(channels.downlink)

        await #expect(throws: SpeechAudioChannelError.flowMismatch) {
            for try await _ in downlink.frames(for: sessionID.audioFlowID) {}
        }
    }

    private func verifyDuplexChannels(
        provider: any SpeechProvider,
        inputFormat: AudioStreamFormat,
        outputFormat: AudioStreamFormat
    ) async throws {
        let configuration = try makeConfiguration(flowID: AudioFlowID())
        let channels = try await provider.startSession(configuration)
        let downlink = try #require(channels.downlink)
        let frames = downlink.frames(for: configuration.sessionID.audioFlowID)
        let uplinkFrame = try makeFrame(
            flowID: configuration.sessionID.audioFlowID,
            format: inputFormat,
            marker: 0x51
        )

        try await channels.uplink.send(uplinkFrame)
        await provider.stopSession(configuration.sessionID)

        let downlinkFrames = try await collect(frames)
        let events = await collect(channels.events)
        let outputFrame = try #require(downlinkFrames.first)
        #expect(downlinkFrames.count == 1)
        #expect(outputFrame.flowID == configuration.sessionID.audioFlowID)
        #expect(outputFrame.format == outputFormat)
        #expect(outputFrame.payload.first == 0x61)
        #expect(events == ContractSessionEndpoint.expectedEvents(for: configuration.sessionID))
        #expect(events.allSatisfy { $0.sessionID == configuration.sessionID })
    }

    private func makeConfiguration(
        flowID: AudioFlowID,
        features: Set<SpeechFeature> = [.transcription, .translation],
        automaticLanguage: Bool = true
    ) throws -> SpeechSessionConfiguration {
        try SpeechSessionConfiguration(
            sessionID: SpeechSessionID(audioFlowID: flowID),
            features: features,
            sourceLanguage: automaticLanguage
                ? .automatic
                : .language(SpeechLanguageTag("en")),
            targetLanguage: features.contains(.translation)
                ? SpeechLanguageTag("zh")
                : nil
        )
    }

    private func makeFrame(
        flowID: AudioFlowID,
        format: AudioStreamFormat,
        marker: UInt8
    ) throws -> AudioFrame {
        var payload = Data(
            count: Int(format.sampleRate / 50) * format.bytesPerFrame
        )
        payload[0] = marker
        return try AudioFrame(
            flowID: flowID,
            sequence: 0,
            timestamp: .zero,
            format: format,
            payload: payload,
            duration: .milliseconds(20)
        )
    }

    private func collect(_ stream: AsyncStream<SpeechEvent>) async -> [SpeechEvent] {
        var values: [SpeechEvent] = []
        for await value in stream { values.append(value) }
        return values
    }

    private func collect(
        _ stream: AsyncThrowingStream<AudioFrame, any Error>
    ) async throws -> [AudioFrame] {
        var values: [AudioFrame] = []
        for try await value in stream { values.append(value) }
        return values
    }
}

private actor ContractFakeProvider: SpeechProvider {
    nonisolated let capabilities: SpeechProviderCapabilities
    private let downlinkFormat: AudioStreamFormat?
    private var endpoints: [SpeechSessionID: ContractSessionEndpoint] = [:]
    private(set) var receivedFrameCount = 0
    private(set) var stopModes: [SpeechSessionStopMode] = []

    init(
        capabilities: SpeechProviderCapabilities,
        downlinkFormat: AudioStreamFormat?
    ) {
        self.capabilities = capabilities
        self.downlinkFormat = downlinkFormat
    }

    func startSession(
        _ configuration: SpeechSessionConfiguration
    ) async throws(SpeechProviderFailure) -> SpeechSessionChannels {
        let replacedEndpoints = endpoints.filter {
            $0.key.audioFlowID == configuration.sessionID.audioFlowID
        }
        for (sessionID, endpoint) in replacedEndpoints {
            await endpoint.stop(reason: .replaced)
            endpoints.removeValue(forKey: sessionID)
        }

        let endpoint = ContractSessionEndpoint(
            sessionID: configuration.sessionID,
            downlinkFormat: downlinkFormat,
            onFrame: { [weak self] in
                await self?.recordFrame()
            }
        )
        endpoints[configuration.sessionID] = endpoint
        return await endpoint.makeChannels()
    }

    func stopSession(
        _ sessionID: SpeechSessionID,
        mode: SpeechSessionStopMode
    ) async -> SpeechSessionStopOutcome {
        stopModes.append(mode)
        guard let endpoint = endpoints.removeValue(forKey: sessionID) else {
            return .noMatchingSession
        }
        await endpoint.stop(reason: .consumerRequested)
        return mode == .graceful ? .graceful : .immediate
    }

    private func recordFrame() {
        receivedFrameCount += 1
    }
}

private actor ContractSessionEndpoint: AudioFrameSender, AudioFrameReceiver {
    nonisolated let sessionID: SpeechSessionID
    nonisolated let downlinkFormat: AudioStreamFormat?
    nonisolated let downlinkPipe = FramePipe()
    private let onFrame: @Sendable () async -> Void
    private let eventStream: AsyncStream<SpeechEvent>
    private let eventContinuation: AsyncStream<SpeechEvent>.Continuation
    private var active = true

    init(
        sessionID: SpeechSessionID,
        downlinkFormat: AudioStreamFormat?,
        onFrame: @escaping @Sendable () async -> Void
    ) {
        self.sessionID = sessionID
        self.downlinkFormat = downlinkFormat
        self.onFrame = onFrame
        (eventStream, eventContinuation) = AsyncStream.makeStream()
        eventContinuation.yield(.sessionStarted(sessionID: sessionID))
    }

    func makeChannels() -> SpeechSessionChannels {
        SpeechSessionChannels(
            sessionID: sessionID,
            events: eventStream,
            uplink: self,
            downlink: downlinkFormat == nil ? nil : self
        )
    }

    func send(_ frame: AudioFrame) async throws {
        guard active else { throw Self.invalidSessionFailure }
        guard sessionID.accepts(frame: frame) else {
            throw SpeechAudioChannelError.flowMismatch
        }

        await onFrame()
        for event in Self.textEvents(for: sessionID) {
            eventContinuation.yield(event)
        }
        if let downlinkFormat {
            var payload = Data(
                count: Int(downlinkFormat.sampleRate / 50)
                    * downlinkFormat.bytesPerFrame
            )
            payload[0] = 0x61
            downlinkPipe.yield(try AudioFrame(
                flowID: sessionID.audioFlowID,
                sequence: frame.sequence,
                timestamp: frame.timestamp,
                format: downlinkFormat,
                payload: payload,
                duration: .milliseconds(20)
            ))
        }
    }

    nonisolated func frames(
        for flowID: AudioFlowID
    ) -> AsyncThrowingStream<AudioFrame, any Error> {
        downlinkPipe.stream(for: flowID)
    }

    func stop(reason: SpeechSessionEndReason) {
        guard active else { return }
        active = false
        eventContinuation.yield(.sessionEnded(sessionID: sessionID, reason: reason))
        eventContinuation.finish()
        downlinkPipe.finish()
    }

    nonisolated static func expectedEvents(
        for sessionID: SpeechSessionID
    ) -> [SpeechEvent] {
        [.sessionStarted(sessionID: sessionID)]
            + textEvents(for: sessionID)
            + [.sessionEnded(sessionID: sessionID, reason: .consumerRequested)]
    }

    nonisolated private static func textEvents(
        for sessionID: SpeechSessionID
    ) -> [SpeechEvent] {
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

    nonisolated private static var invalidSessionFailure: SpeechProviderFailure {
        SpeechProviderFailure(
            classification: .invalidSession,
            type: try! SpeechFailureIdentifier("inactive_session"),
            code: nil
        )
    }
}

private final class FramePipe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:
        AsyncThrowingStream<AudioFrame, any Error>.Continuation?
    private var pendingFrames: [AudioFrame] = []
    private var finished = false

    func stream(
        for flowID: AudioFlowID
    ) -> AsyncThrowingStream<AudioFrame, any Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.finish()
                return
            }
            self.continuation = continuation
            let frames = pendingFrames.filter { $0.flowID == flowID }
            pendingFrames.removeAll()
            lock.unlock()
            for frame in frames { continuation.yield(frame) }
        }
    }

    func yield(_ frame: AudioFrame) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if let continuation {
            lock.unlock()
            continuation.yield(frame)
        } else {
            pendingFrames.append(frame)
            lock.unlock()
        }
    }

    func finish() {
        lock.lock()
        finished = true
        let continuation = continuation
        self.continuation = nil
        pendingFrames.removeAll()
        lock.unlock()
        continuation?.finish()
    }
}

private actor RecordingSender: AudioFrameSender {
    func send(_ frame: AudioFrame) async throws {}
}

private func requireSendable<T: Sendable>(_: T) {}

private struct FixedReceiver: AudioFrameReceiver {
    let storedFrames: [AudioFrame]

    init(frames: [AudioFrame]) {
        storedFrames = frames
    }

    func frames(
        for flowID: AudioFlowID
    ) -> AsyncThrowingStream<AudioFrame, any Error> {
        AsyncThrowingStream { continuation in
            for frame in storedFrames {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }
}

private extension SpeechProviderCapabilities {
    static func cloud(
        inputFormat: AudioStreamFormat,
        outputFormat: AudioStreamFormat
    ) -> Self {
        Self(
            requiresNetwork: true,
            credentialRequirement: .callerInjected,
            supportedFeatures: [.transcription, .translation],
            acceptedInputFormats: [inputFormat],
            outputAudioFormats: [outputFormat],
            supportsAutomaticSourceLanguage: true,
            reportsDetectedSourceLanguage: false
        )
    }
}
