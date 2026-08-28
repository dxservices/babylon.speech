import BabylonAudio
import BabylonSpeech
import Foundation
import XCTest
@testable import BabylonSpeechOpenAI

@available(iOS 18, macOS 15, *)
@MainActor
final class OpenAIRealtimeSpeechProviderTests: XCTestCase {
    func testCapabilitiesDescribeTranslationRealtimeContract() throws {
        let provider: any SpeechProvider = OpenAIRealtimeSpeechProvider(
            authorization: .init(clientSecret: "test-client-secret")
        )
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)

        XCTAssertEqual(
            provider.capabilities,
            SpeechProviderCapabilities(
                requiresNetwork: true,
                credentialRequirement: .callerInjected,
                supportedFeatures: [.transcription, .translation],
                acceptedInputFormats: [format],
                outputAudioFormats: [format],
                supportsAutomaticSourceLanguage: true,
                reportsDetectedSourceLanguage: false,
                requiredFeatures: [.translation],
                supportsExplicitSourceLanguage: false
            )
        )
    }

    func testUnsupportedConfigurationsFailClosedBeforeTransportCreation()
        async throws
    {
        let factory = TestSpeechTransportFactory()
        let provider = makeProvider(factory: factory)
        let flowID = AudioFlowID()
        let configurations = [
            try SpeechSessionConfiguration(
                sessionID: .init(audioFlowID: flowID),
                features: [.transcription],
                sourceLanguage: .automatic
            ),
            try SpeechSessionConfiguration(
                sessionID: .init(audioFlowID: flowID),
                features: [.translation],
                sourceLanguage: .language(SpeechLanguageTag("en")),
                targetLanguage: SpeechLanguageTag("fr")
            ),
        ]

        for configuration in configurations {
            let failure = await startFailure(provider, configuration)
            XCTAssertEqual(failure.classification, .unsupportedConfiguration)
            XCTAssertEqual(failure.type.value, "invalid_configuration")
            XCTAssertEqual(
                failure.code?.value,
                "unsupported_session_configuration"
            )
        }
        XCTAssertTrue(factory.transports.isEmpty)
    }

    func testUnsupportedConfigurationDoesNotReplaceActiveEndpoint()
        async throws
    {
        let factory = TestSpeechTransportFactory()
        let provider = makeProvider(factory: factory)
        let flowID = AudioFlowID()
        let activeConfiguration = try makeConfiguration(flowID: flowID)
        let start = Task { @MainActor in
            try await provider.startSession(activeConfiguration)
        }
        await waitUntil { factory.transports.count == 1 }
        let activeTransport = factory.transports[0]
        activeTransport.completeConnect()
        let activeChannels = try await start.value
        let unsupported = try SpeechSessionConfiguration(
            sessionID: .init(audioFlowID: flowID),
            features: [.transcription],
            sourceLanguage: .automatic
        )

        _ = await startFailure(provider, unsupported)
        try await activeChannels.uplink.send(try makeFrame(flowID: flowID))

        XCTAssertEqual(factory.transports.count, 1)
        XCTAssertEqual(activeTransport.cancelCallCount, 0)
        XCTAssertEqual(activeTransport.sentPayloads.count, 1)
        await provider.stopSession(activeConfiguration.sessionID)
    }

    func testStartWaitsForFullConnectionThenYieldsStartedAndChannels()
        async throws
    {
        let factory = TestSpeechTransportFactory()
        let provider = makeProvider(factory: factory)
        let configuration = try makeConfiguration(
            features: [.transcription, .translation]
        )
        var channels: SpeechSessionChannels?
        let start = Task { @MainActor in
            channels = try await provider.startSession(configuration)
        }
        await waitUntil { factory.transports.count == 1 }
        let transport = try XCTUnwrap(factory.transports.first)
        await waitUntil { transport.isConnectPending }

        XCTAssertNil(channels)
        XCTAssertEqual(transport.targetLanguage, "fr")
        XCTAssertEqual(transport.transcriptionRequested, true)
        XCTAssertEqual(
            transport.audioBinding?.sessionID,
            configuration.sessionID
        )
        XCTAssertEqual(transport.includeDownlink, true)

        transport.completeConnect()
        try await start.value
        let connected = try XCTUnwrap(channels)
        XCTAssertEqual(connected.sessionID, configuration.sessionID)
        let probe = SpeechEventProbe(stream: connected.events)
        await waitUntil { probe.events.count == 1 }
        XCTAssertEqual(
            probe.events,
            [.sessionStarted(sessionID: configuration.sessionID)]
        )

        await provider.stopSession(configuration.sessionID)
        await waitUntil { probe.isComplete }
    }

    func testEventsArrivingSynchronouslyDuringConnectReplayAfterStarted()
        async throws
    {
        let factory = TestSpeechTransportFactory()
        factory.synchronousEventsForNextConnect = [
            .translatedTranscriptDelta("during-connect"),
        ]
        let provider = makeProvider(factory: factory)
        let configuration = try makeConfiguration()
        let start = Task { @MainActor in
            try await provider.startSession(configuration)
        }
        await waitUntil { factory.transports.count == 1 }
        let transport = factory.transports[0]
        await waitUntil { transport.isConnectPending }
        transport.completeConnect()
        let channels = try await start.value
        let probe = SpeechEventProbe(stream: channels.events)
        await waitUntil { probe.events.count == 2 }

        XCTAssertEqual(probe.events, [
            .sessionStarted(sessionID: configuration.sessionID),
            translationDelta(
                "during-connect",
                id: 0,
                configuration: configuration
            ),
        ])
        await provider.stopSession(configuration.sessionID)
    }

    func testStartingEventStagingOverflowFailsClosedAndCancelsTransport()
        async throws
    {
        let factory = TestSpeechTransportFactory()
        factory.synchronousEventsForNextConnect = Array(
            repeating: .translatedTranscriptDelta("x"),
            count: 129
        )
        let provider = makeProvider(factory: factory)
        let configuration = try makeConfiguration()

        let failure = await startFailure(provider, configuration)

        XCTAssertEqual(failure.classification, .provider)
        XCTAssertEqual(failure.type.value, "provider_error")
        XCTAssertEqual(failure.code?.value, "event_staging_overflow")
        XCTAssertEqual(factory.transports.count, 1)
        XCTAssertEqual(factory.transports[0].cancelCallCount, 1)
    }

    func testExactly128StartingEventsReplayAfterStarted() async throws {
        let factory = TestSpeechTransportFactory()
        factory.synchronousEventsForNextConnect = Array(
            repeating: .translatedTranscriptDelta("x"),
            count: 128
        )
        let provider = makeProvider(factory: factory)
        let configuration = try makeConfiguration()
        let start = Task { @MainActor in
            try await provider.startSession(configuration)
        }
        await waitUntil { factory.transports.count == 1 }
        factory.transports[0].completeConnect()
        let channels = try await start.value
        let probe = SpeechEventProbe(stream: channels.events)
        await waitUntil { probe.events.count == 129 }

        XCTAssertEqual(
            probe.events.first,
            .sessionStarted(sessionID: configuration.sessionID)
        )
        XCTAssertEqual(probe.events.dropFirst().count, 128)
        XCTAssertTrue(probe.events.dropFirst().allSatisfy { event in
            if case .translation = event { return true }
            return false
        })
        await provider.stopSession(configuration.sessionID)
    }

    func testSynchronousRemoteTerminalDuringConnectFailsWithoutChannels()
        async throws
    {
        let factory = TestSpeechTransportFactory()
        factory.synchronousEventsForNextConnect = [.sessionClosed]
        let provider = makeProvider(factory: factory)
        let configuration = try makeConfiguration()

        let failure = await startFailure(provider, configuration)

        XCTAssertEqual(failure.classification, .network)
        XCTAssertEqual(failure.type.value, "network_error")
        XCTAssertEqual(failure.code?.value, "connection_closed")
        XCTAssertEqual(factory.transports.count, 1)
        XCTAssertEqual(factory.transports[0].cancelCallCount, 1)
    }

    func testStartingTransportFailuresPreserveExactFailure()
        async throws
    {
        let cases: [SpeechProviderFailure] = [
            makeFailure(code: "connection_timed_out"),
            makeFailure(code: "session_update_failed"),
        ]
        for expectedFailure in cases {
            let factory = TestSpeechTransportFactory()
            let provider = makeProvider(factory: factory)
            let configuration = try makeConfiguration()
            let start = Task { @MainActor in
                try await provider.startSession(configuration)
            }
            await waitUntil { factory.transports.count == 1 }
            let transport = factory.transports[0]
            await waitUntil { transport.isConnectPending }

            transport.failConnect(expectedFailure)

            let failure = await taskFailure(start)
            XCTAssertEqual(failure, expectedFailure)
        }

        let factory = TestSpeechTransportFactory()
        let provider = makeProvider(factory: factory)
        let configuration = try makeConfiguration()
        let cancelled = Task { @MainActor in
            try await provider.startSession(configuration)
        }
        await waitUntil { factory.transports.count == 1 }
        await waitUntil { factory.transports[0].isConnectPending }
        cancelled.cancel()

        let cancellationFailure = await taskFailure(cancelled)
        XCTAssertEqual(
            cancellationFailure.code?.value,
            "connection_cancelled"
        )
    }

    func testDecodedEventsMapExactlyAndRemoteCloseCompletesWithEOF()
        async throws
    {
        let context = try await makeConnectedProvider()
        let probe = SpeechEventProbe(stream: context.channels.events)
        let downlink = try XCTUnwrap(context.channels.downlink)
        var iterator = downlink.frames(
            for: context.configuration.sessionID.audioFlowID
        ).makeAsyncIterator()
        await waitUntil { probe.events.count == 1 }

        context.transport.emit(.sourceTranscriptDelta("source"))
        context.transport.emit(.translatedTranscriptDelta("target"))
        context.transport.emit(.sessionClosed)
        context.transport.emitTerminal(
            makeFailure(code: "late_terminal")
        )
        await waitUntil { probe.isComplete }

        XCTAssertEqual(probe.events, [
            .sessionStarted(sessionID: context.configuration.sessionID),
            transcriptionDelta(
                "source",
                id: 0,
                configuration: context.configuration
            ),
            translationDelta(
                "target",
                id: 1,
                configuration: context.configuration
            ),
            transcriptionCompletion(
                "source",
                id: 0,
                configuration: context.configuration
            ),
            translationCompletion(
                "target",
                id: 1,
                configuration: context.configuration
            ),
            .sessionEnded(
                sessionID: context.configuration.sessionID,
                reason: .completed
            ),
        ])
        let terminalFrame = try await iterator.next()
        XCTAssertNil(terminalFrame)
        XCTAssertTrue(
            probe.events.allSatisfy {
                $0.sessionID == context.configuration.sessionID
            }
        )
    }

    func testDifferentFlowsRemainIndependent() async throws {
        let factory = TestSpeechTransportFactory()
        let provider = makeProvider(factory: factory)
        let firstConfiguration = try makeConfiguration()
        let secondConfiguration = try makeConfiguration()
        let firstStart = Task { @MainActor in
            try await provider.startSession(firstConfiguration)
        }
        await waitUntil { factory.transports.count == 1 }
        factory.transports[0].completeConnect()
        let first = try await firstStart.value
        let secondStart = Task { @MainActor in
            try await provider.startSession(secondConfiguration)
        }
        await waitUntil { factory.transports.count == 2 }
        factory.transports[1].completeConnect()
        let second = try await secondStart.value
        let secondProbe = SpeechEventProbe(stream: second.events)

        await provider.stopSession(firstConfiguration.sessionID)
        factory.transports[1].emit(.translatedTranscriptDelta("alive"))
        await waitUntil { secondProbe.events.count == 2 }

        XCTAssertEqual(factory.transports[0].closeCallCount, 1)
        XCTAssertEqual(factory.transports[1].closeCallCount, 0)
        XCTAssertEqual(
            secondProbe.events[1],
            translationDelta(
                "alive",
                id: 0,
                configuration: secondConfiguration
            )
        )
        _ = first
        await provider.stopSession(secondConfiguration.sessionID)
    }

    func testSameFlowReplacementStalesOldChannelsAndFlushesMapper()
        async throws
    {
        let factory = TestSpeechTransportFactory()
        let provider = makeProvider(factory: factory)
        let flowID = AudioFlowID()
        let oldConfiguration = try makeConfiguration(flowID: flowID)
        let oldStart = Task { @MainActor in
            try await provider.startSession(oldConfiguration)
        }
        await waitUntil { factory.transports.count == 1 }
        let oldTransport = factory.transports[0]
        oldTransport.completeConnect()
        let oldChannels = try await oldStart.value
        let oldProbe = SpeechEventProbe(stream: oldChannels.events)
        let oldDownlink = try XCTUnwrap(oldChannels.downlink)
        var oldIterator = oldDownlink.frames(for: flowID).makeAsyncIterator()
        oldTransport.emit(.sourceTranscriptDelta("partial"))

        let newConfiguration = try makeConfiguration(flowID: flowID)
        let retainedOldEvent = oldTransport.onEvent
        let retainedOldTerminal = oldTransport.onTerminal
        let newStart = Task { @MainActor in
            try await provider.startSession(newConfiguration)
        }
        await waitUntil { factory.transports.count == 2 }
        let newTransport = factory.transports[1]
        await waitUntil { oldProbe.isComplete }

        XCTAssertEqual(oldProbe.events.suffix(2), [
            transcriptionCompletion(
                "partial",
                id: 0,
                configuration: oldConfiguration
            ),
            .sessionEnded(
                sessionID: oldConfiguration.sessionID,
                reason: .replaced
            ),
        ])
        let frame = try makeFrame(flowID: flowID)
        await XCTAssertThrowsErrorAsync {
            try await oldChannels.uplink.send(frame)
        } verify: { error in
            XCTAssertEqual(error as? OpenAIRealtimeAudioChannelError, .staleFlow)
        }
        do {
            _ = try await oldIterator.next()
            XCTFail("Expected stale downlink")
        } catch let error as OpenAIRealtimeAudioChannelError {
            XCTAssertEqual(error, .staleFlow)
        }
        XCTAssertEqual(oldTransport.cancelCallCount, 1)

        newTransport.completeConnect()
        let newChannels = try await newStart.value
        let newProbe = SpeechEventProbe(stream: newChannels.events)
        let lateOldFailure = makeFailure(code: "late_old")
        retainedOldEvent?(.providerFailure(lateOldFailure))
        retainedOldTerminal?(lateOldFailure)
        newTransport.emit(.translatedTranscriptDelta("new"))
        await waitUntil { newProbe.events.count == 2 }
        XCTAssertEqual(
            newProbe.events[1],
            translationDelta(
                "new",
                id: 0,
                configuration: newConfiguration
            )
        )
        await provider.stopSession(newConfiguration.sessionID)
    }

    func testPendingReplacementAndCallerCancellationAreGenerationIsolated()
        async throws
    {
        let factory = TestSpeechTransportFactory()
        let provider = makeProvider(factory: factory)
        let flowID = AudioFlowID()
        let oldConfiguration = try makeConfiguration(flowID: flowID)
        let oldStart = Task { @MainActor in
            try await provider.startSession(oldConfiguration)
        }
        await waitUntil { factory.transports.count == 1 }
        let oldTransport = factory.transports[0]
        await waitUntil { oldTransport.isConnectPending }

        let replacementConfiguration = try makeConfiguration(flowID: flowID)
        let replacement = Task { @MainActor in
            try await provider.startSession(replacementConfiguration)
        }
        await waitUntil { factory.transports.count == 2 }
        let replacementTransport = factory.transports[1]
        let oldFailure = await taskFailure(oldStart)
        XCTAssertEqual(oldFailure.code?.value, "connection_cancelled")

        replacementTransport.completeConnect()
        let replacementChannels = try await replacement.value
        let cancelledConfiguration = try makeConfiguration(flowID: flowID)
        let cancelledStart = Task { @MainActor in
            try await provider.startSession(cancelledConfiguration)
        }
        await waitUntil { factory.transports.count == 3 }
        let cancelledTransport = factory.transports[2]
        await waitUntil { cancelledTransport.isConnectPending }
        cancelledStart.cancel()
        let cancellationFailure = await taskFailure(cancelledStart)
        XCTAssertEqual(cancellationFailure.code?.value, "connection_cancelled")

        let finalConfiguration = try makeConfiguration(flowID: flowID)
        let finalStart = Task { @MainActor in
            try await provider.startSession(finalConfiguration)
        }
        await waitUntil { factory.transports.count == 4 }
        let finalTransport = factory.transports[3]
        finalTransport.completeConnect()
        let finalChannels = try await finalStart.value
        try await finalChannels.uplink.send(try makeFrame(flowID: flowID))

        XCTAssertEqual(oldTransport.cancelCallCount, 1)
        XCTAssertEqual(cancelledTransport.cancelCallCount, 1)
        _ = replacementChannels
        await provider.stopSession(finalConfiguration.sessionID)
    }

    func testDuplicateExactSessionIDFailsClosedWhilePendingOrLive()
        async throws
    {
        let factory = TestSpeechTransportFactory()
        let provider = makeProvider(factory: factory)
        let configuration = try makeConfiguration()
        let start = Task { @MainActor in
            try await provider.startSession(configuration)
        }
        await waitUntil { factory.transports.count == 1 }
        await waitUntil { factory.transports[0].isConnectPending }

        let pendingFailure = await startFailure(provider, configuration)
        XCTAssertEqual(pendingFailure.classification, .invalidSession)
        XCTAssertEqual(pendingFailure.type.value, "invalid_session")
        XCTAssertEqual(pendingFailure.code?.value, "duplicate_session_id")
        XCTAssertEqual(factory.transports.count, 1)

        factory.transports[0].completeConnect()
        _ = try await start.value
        let liveFailure = await startFailure(provider, configuration)
        XCTAssertEqual(liveFailure.classification, .invalidSession)
        XCTAssertEqual(liveFailure.type.value, "invalid_session")
        XCTAssertEqual(liveFailure.code?.value, "duplicate_session_id")
        XCTAssertEqual(factory.transports.count, 1)
        await provider.stopSession(configuration.sessionID)
    }

    func testStopDuringPendingStartCancelsAndAllowsSafeSameIDReuse()
        async throws
    {
        let factory = TestSpeechTransportFactory()
        let provider = makeProvider(factory: factory)
        let configuration = try makeConfiguration()
        let pending = Task { @MainActor in
            try await provider.startSession(configuration)
        }
        await waitUntil { factory.transports.count == 1 }
        await waitUntil { factory.transports[0].isConnectPending }

        await provider.stopSession(configuration.sessionID)
        let failure = await taskFailure(pending)

        XCTAssertEqual(failure.code?.value, "connection_cancelled")
        XCTAssertEqual(factory.transports[0].cancelCallCount, 1)

        let reused = Task { @MainActor in
            try await provider.startSession(configuration)
        }
        await waitUntil { factory.transports.count == 2 }
        factory.transports[1].completeConnect()
        _ = try await reused.value
        await provider.stopSession(configuration.sessionID)
    }

    func testStopSuccessFlushesConsumerRequestedAndFinishesDownlink()
        async throws
    {
        let context = try await makeConnectedProvider()
        let probe = SpeechEventProbe(stream: context.channels.events)
        let receiver = try XCTUnwrap(context.channels.downlink)
        var iterator = receiver.frames(
            for: context.configuration.sessionID.audioFlowID
        ).makeAsyncIterator()
        context.transport.emit(.translatedTranscriptDelta("partial"))

        await context.provider.stopSession(context.configuration.sessionID)
        await waitUntil { probe.isComplete }

        XCTAssertEqual(probe.events.suffix(2), [
            translationCompletion(
                "partial",
                id: 0,
                configuration: context.configuration
            ),
            .sessionEnded(
                sessionID: context.configuration.sessionID,
                reason: .consumerRequested
            ),
        ])
        let terminalFrame = try await iterator.next()
        XCTAssertNil(terminalFrame)
        XCTAssertEqual(context.transport.closeCallCount, 1)
    }

    func testStopFirstWinsConsumerReasonAcrossLateCloseOutcomes()
        async throws
    {
        let outcomes: [OpenAIRealtimeCloseOutcome] = [
            .serverAcknowledged,
            .failed,
            .localForcedAfterTimeout,
        ]
        for outcome in outcomes {
            let context = try await makeConnectedProvider()
            context.transport.closeOutcome = outcome
            let probe = SpeechEventProbe(stream: context.channels.events)

            await context.provider.stopSession(context.configuration.sessionID)
            await waitUntil { probe.isComplete }

            XCTAssertEqual(probe.events, [
                .sessionStarted(sessionID: context.configuration.sessionID),
                .sessionEnded(
                    sessionID: context.configuration.sessionID,
                    reason: .consumerRequested
                ),
            ])
        }
    }

    func testStopDetachesTextBeforeGracefulDrainCompletes() async throws {
        let context = try await makeConnectedProvider()
        context.transport.suspendsClose = true
        let probe = SpeechEventProbe(stream: context.channels.events)
        let stop = Task { @MainActor in
            await context.provider.stopSession(context.configuration.sessionID)
        }
        await waitUntil { context.transport.isClosePending }
        await waitUntil { probe.isComplete }

        context.transport.emit(.translatedTranscriptDelta("late"))
        context.transport.emitTerminal(
            makeFailure(code: "late_terminal")
        )
        context.transport.completeClose(.localForcedAfterTimeout)
        await stop.value

        XCTAssertEqual(probe.events, [
            .sessionStarted(sessionID: context.configuration.sessionID),
            .sessionEnded(
                sessionID: context.configuration.sessionID,
                reason: .consumerRequested
            ),
        ])
    }

    func testNetworkTerminalEmitsFailureBeforeFlushAndFailedEnd()
        async throws
    {
        let context = try await makeConnectedProvider()
        let probe = SpeechEventProbe(stream: context.channels.events)
        let recoverableFailure = makeFailure(
            code: "recoverable_provider_error"
        )
        context.transport.emit(.providerFailure(recoverableFailure))
        context.transport.emit(.sourceTranscriptDelta("partial"))
        let terminalFailure = makeFailure(code: "connection_closed")

        context.transport.emit(.providerFailure(terminalFailure))
        context.transport.emitTerminal(terminalFailure)
        await waitUntil { probe.isComplete }

        XCTAssertEqual(
            probe.events.filter {
                if case .failure = $0 { return true }
                return false
            }.count,
            2
        )
        XCTAssertEqual(probe.events.suffix(3), [
            .failure(
                sessionID: context.configuration.sessionID,
                failure: terminalFailure
            ),
            transcriptionCompletion(
                "partial",
                id: 0,
                configuration: context.configuration
            ),
            .sessionEnded(
                sessionID: context.configuration.sessionID,
                reason: .failed
            ),
        ])
    }

    func testMapperSegmentExhaustionCancelsTransport() async throws {
        let factory = TestSpeechTransportFactory()
        let provider = makeProvider(
            factory: factory,
            initialSegmentRawValue: .max
        )
        let configuration = try makeConfiguration()
        let start = Task { @MainActor in
            try await provider.startSession(configuration)
        }
        await waitUntil { factory.transports.count == 1 }
        let transport = factory.transports[0]
        transport.completeConnect()
        let channels = try await start.value
        let probe = SpeechEventProbe(stream: channels.events)
        transport.emit(.sourceTranscriptDelta("last"))
        transport.emit(.sourceTranscriptCompleted(nil))

        transport.emit(.translatedTranscriptDelta("overflow"))
        await waitUntil { probe.isComplete }

        XCTAssertEqual(transport.cancelCallCount, 1)
        guard case let .failure(_, failure) = probe.events.dropLast().last
        else {
            return XCTFail("Expected mapper exhaustion failure")
        }
        XCTAssertEqual(failure.type.value, "segment_sequence_exhausted")
        XCTAssertEqual(
            probe.events.last,
            .sessionEnded(
                sessionID: configuration.sessionID,
                reason: .failed
            )
        )
    }

    func testLateCallbacksCannotRemoveReusedSameIDEndpoint()
        async throws
    {
        let factory = TestSpeechTransportFactory()
        let provider = makeProvider(factory: factory)
        let configuration = try makeConfiguration()
        let oldStart = Task { @MainActor in
            try await provider.startSession(configuration)
        }
        await waitUntil { factory.transports.count == 1 }
        let oldTransport = factory.transports[0]
        oldTransport.completeConnect()
        _ = try await oldStart.value
        await provider.stopSession(configuration.sessionID)

        let reused = Task { @MainActor in
            try await provider.startSession(configuration)
        }
        await waitUntil { factory.transports.count == 2 }
        let reusedTransport = factory.transports[1]
        reusedTransport.completeConnect()
        let reusedChannels = try await reused.value
        oldTransport.emit(.providerFailure(makeFailure(code: "late_old")))
        oldTransport.emitTerminal(
            makeFailure(code: "late_terminal")
        )

        try await reusedChannels.uplink.send(
            try makeFrame(flowID: configuration.sessionID.audioFlowID)
        )
        await provider.stopSession(configuration.sessionID)
        XCTAssertEqual(reusedTransport.closeCallCount, 1)
    }

    private func makeProvider(
        factory: TestSpeechTransportFactory,
        initialSegmentRawValue: UInt64 = 0
    ) -> OpenAIRealtimeSpeechProvider {
        OpenAIRealtimeSpeechProvider(
            authorization: .init(clientSecret: "test-client-secret"),
            transportFactory: { factory.makeTransport() },
            initialSegmentRawValue: initialSegmentRawValue
        )
    }

    private func makeConnectedProvider() async throws -> (
        provider: OpenAIRealtimeSpeechProvider,
        transport: TestSpeechSessionTransport,
        configuration: SpeechSessionConfiguration,
        channels: SpeechSessionChannels
    ) {
        let factory = TestSpeechTransportFactory()
        let provider = makeProvider(factory: factory)
        let configuration = try makeConfiguration()
        let start = Task { @MainActor in
            try await provider.startSession(configuration)
        }
        await waitUntil { factory.transports.count == 1 }
        let transport = factory.transports[0]
        transport.completeConnect()
        return (
            provider,
            transport,
            configuration,
            try await start.value
        )
    }

    private func makeConfiguration(
        flowID: AudioFlowID = .init(),
        features: Set<SpeechFeature> = [.transcription, .translation]
    ) throws -> SpeechSessionConfiguration {
        try SpeechSessionConfiguration(
            sessionID: SpeechSessionID(audioFlowID: flowID),
            features: features,
            sourceLanguage: .automatic,
            targetLanguage: SpeechLanguageTag("fr")
        )
    }

    private func makeFrame(flowID: AudioFlowID) throws -> AudioFrame {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        return try AudioFrame(
            flowID: flowID,
            sequence: 0,
            timestamp: .zero,
            format: format,
            payload: Data([0x01, 0x02]),
            duration: try format.duration(forPayloadByteCount: 2)
        )
    }

    private func startFailure(
        _ provider: OpenAIRealtimeSpeechProvider,
        _ configuration: SpeechSessionConfiguration
    ) async -> SpeechProviderFailure {
        do {
            _ = try await provider.startSession(configuration)
            XCTFail("Expected start failure")
        } catch let failure {
            return failure
        }
        return makeFailure(code: "unexpected_test_failure")
    }

    private func taskFailure(
        _ task: Task<SpeechSessionChannels, any Error>
    ) async -> SpeechProviderFailure {
        do {
            _ = try await task.value
            XCTFail("Expected task failure")
        } catch let failure as SpeechProviderFailure {
            return failure
        } catch {
            XCTFail("Expected fixed provider failure")
        }
        return makeFailure(code: "unexpected_test_failure")
    }

    private func makeFailure(code: String) -> SpeechProviderFailure {
        SpeechProviderFailure(
            classification: .network,
            type: try! SpeechFailureIdentifier("network_error"),
            code: try! SpeechFailureIdentifier(code)
        )
    }

    private func transcriptionDelta(
        _ text: String,
        id: UInt64,
        configuration: SpeechSessionConfiguration
    ) -> SpeechEvent {
        .transcription(
            sessionID: configuration.sessionID,
            text: .delta(.init(
                segmentID: .init(rawValue: id),
                text: text,
                language: nil
            ))
        )
    }

    private func transcriptionCompletion(
        _ text: String,
        id: UInt64,
        configuration: SpeechSessionConfiguration
    ) -> SpeechEvent {
        .transcription(
            sessionID: configuration.sessionID,
            text: .completed(.init(
                segmentID: .init(rawValue: id),
                text: text,
                language: nil
            ))
        )
    }

    private func translationDelta(
        _ text: String,
        id: UInt64,
        configuration: SpeechSessionConfiguration
    ) -> SpeechEvent {
        .translation(
            sessionID: configuration.sessionID,
            text: .delta(.init(
                segmentID: .init(rawValue: id),
                text: text,
                language: configuration.targetLanguage
            ))
        )
    }

    private func translationCompletion(
        _ text: String,
        id: UInt64,
        configuration: SpeechSessionConfiguration
    ) -> SpeechEvent {
        .translation(
            sessionID: configuration.sessionID,
            text: .completed(.init(
                segmentID: .init(rawValue: id),
                text: text,
                language: configuration.targetLanguage
            ))
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        attempts: Int = 200
    ) async {
        for _ in 0..<attempts {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Condition was not met")
    }
}

@available(iOS 18, macOS 15, *)
@MainActor
private final class TestSpeechTransportFactory {
    private(set) var transports: [TestSpeechSessionTransport] = []
    var synchronousEventsForNextConnect: [OpenAIRealtimeDecodedEvent] = []

    func makeTransport() -> any OpenAIRealtimeSpeechSessionTransport {
        let transport = TestSpeechSessionTransport(
            synchronousConnectEvents: synchronousEventsForNextConnect
        )
        synchronousEventsForNextConnect = []
        transports.append(transport)
        return transport
    }
}

@available(iOS 18, macOS 15, *)
@MainActor
private final class TestSpeechSessionTransport:
    OpenAIRealtimeSpeechSessionTransport
{
    var onEvent: (@MainActor @Sendable (OpenAIRealtimeDecodedEvent) -> Void)?
    var onTerminal: (
        @MainActor @Sendable (SpeechProviderFailure) -> Void
    )?

    private var connectContinuation: CheckedContinuation<
        Result<OpenAIRealtimeAudioChannels, SpeechProviderFailure>,
        Never
    >?
    private var closeContinuation: CheckedContinuation<
        OpenAIRealtimeCloseOutcome,
        Never
    >?
    private(set) var targetLanguage: String?
    private(set) var transcriptionRequested: Bool?
    private(set) var audioBinding: OpenAIRealtimeAudioBinding?
    private(set) var includeDownlink: Bool?
    private(set) var channels: OpenAIRealtimeAudioChannels?
    private(set) var sentPayloads: [Data] = []
    private(set) var closeCallCount = 0
    private(set) var cancelCallCount = 0
    var closeOutcome: OpenAIRealtimeCloseOutcome = .serverAcknowledged
    var suspendsClose = false
    private var synchronousConnectEvents: [OpenAIRealtimeDecodedEvent]

    init(synchronousConnectEvents: [OpenAIRealtimeDecodedEvent]) {
        self.synchronousConnectEvents = synchronousConnectEvents
    }

    var isConnectPending: Bool { connectContinuation != nil }
    var isClosePending: Bool { closeContinuation != nil }

    func connect(
        targetLanguage: String,
        transcriptionRequested: Bool,
        audioBinding: OpenAIRealtimeAudioBinding,
        includeDownlink: Bool
    ) async throws(SpeechProviderFailure) -> OpenAIRealtimeAudioChannels {
        self.targetLanguage = targetLanguage
        self.transcriptionRequested = transcriptionRequested
        self.audioBinding = audioBinding
        self.includeDownlink = includeDownlink
        let result: Result<
            OpenAIRealtimeAudioChannels,
            SpeechProviderFailure
        > = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                connectContinuation = continuation
                let events = synchronousConnectEvents
                synchronousConnectEvents = []
                for event in events {
                    onEvent?(event)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.failConnect(Self.connectionCancelledFailure)
            }
        }
        switch result {
        case let .success(channels):
            return channels
        case let .failure(failure):
            throw failure
        }
    }

    func closeGracefully() async -> OpenAIRealtimeCloseOutcome {
        closeCallCount += 1
        if !suspendsClose { return closeOutcome }
        return await withCheckedContinuation { continuation in
            closeContinuation = continuation
        }
    }

    @discardableResult
    func cancelImmediately() -> OpenAIRealtimeCloseOutcome {
        cancelCallCount += 1
        failConnect(Self.connectionCancelledFailure)
        if let closeContinuation {
            self.closeContinuation = nil
            closeContinuation.resume(returning: .localImmediate)
        }
        return .localImmediate
    }

    func completeClose(_ outcome: OpenAIRealtimeCloseOutcome) {
        guard let closeContinuation else { return }
        self.closeContinuation = nil
        closeContinuation.resume(returning: outcome)
    }

    func completeConnect() {
        guard let audioBinding,
              let includeDownlink,
              let continuation = connectContinuation
        else { return }
        connectContinuation = nil
        let channels = OpenAIRealtimeAudioChannels(
            binding: audioBinding,
            sendPCM16: { [weak self] _, payload in
                guard let self else {
                    throw OpenAIRealtimeAudioChannelError.transportClosed
                }
                await self.record(payload)
            },
            includeReceiver: includeDownlink
        )
        self.channels = channels
        continuation.resume(returning: .success(channels))
    }

    func failConnect(_ failure: SpeechProviderFailure) {
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        continuation.resume(returning: .failure(failure))
    }

    func emit(_ event: OpenAIRealtimeDecodedEvent) {
        onEvent?(event)
    }

    func emitTerminal(_ failure: SpeechProviderFailure) {
        onTerminal?(failure)
    }

    private func record(_ payload: Data) {
        sentPayloads.append(payload)
    }

    private static let connectionCancelledFailure = SpeechProviderFailure(
        classification: .network,
        type: try! SpeechFailureIdentifier("network_error"),
        code: try! SpeechFailureIdentifier("connection_cancelled")
    )
}

@available(iOS 18, macOS 15, *)
@MainActor
private final class SpeechEventProbe {
    private(set) var events: [SpeechEvent] = []
    private(set) var isComplete = false
    private var task: Task<Void, Never>?

    init(stream: AsyncStream<SpeechEvent>) {
        task = Task { @MainActor in
            for await event in stream {
                events.append(event)
            }
            isComplete = true
        }
    }
}

@available(iOS 18, macOS 15, *)
@MainActor
private func XCTAssertThrowsErrorAsync(
    _ operation: @escaping @MainActor () async throws -> Void,
    verify: @escaping @MainActor (any Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
