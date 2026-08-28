import BabylonAudio
import BabylonSpeech
import Foundation

@available(iOS 18, macOS 15, *)
@MainActor
public final class OpenAIRealtimeSpeechProvider: SpeechProvider {
    typealias TransportFactory = @MainActor @Sendable ()
        -> any OpenAIRealtimeSpeechSessionTransport

    public nonisolated let capabilities: SpeechProviderCapabilities

    private let transportFactory: TransportFactory
    private let initialSegmentRawValue: UInt64
    private var endpoints: [AudioFlowID: OpenAIRealtimeSpeechSessionEndpoint]
        = [:]

    public init(authorization: OpenAIRealtimeAuthorization) {
        capabilities = Self.makeCapabilities()
        initialSegmentRawValue = 0
        transportFactory = {
            OpenAIRealtimeWebSocketTransport(authorization: authorization)
        }
    }

    init(
        authorization: OpenAIRealtimeAuthorization,
        transportFactory: @escaping TransportFactory,
        initialSegmentRawValue: UInt64 = 0
    ) {
        _ = authorization
        capabilities = Self.makeCapabilities()
        self.transportFactory = transportFactory
        self.initialSegmentRawValue = initialSegmentRawValue
    }

    public func startSession(
        _ configuration: SpeechSessionConfiguration
    ) async throws(SpeechProviderFailure) -> SpeechSessionChannels {
        guard capabilities.supports(configuration),
              let targetLanguage = configuration.targetLanguage
        else {
            throw Self.failure(
                classification: .unsupportedConfiguration,
                type: "invalid_configuration",
                code: "unsupported_session_configuration"
            )
        }

        let flowID = configuration.sessionID.audioFlowID
        if let current = endpoints[flowID],
           current.sessionID == configuration.sessionID
        {
            throw Self.failure(
                classification: .invalidSession,
                type: "invalid_session",
                code: "duplicate_session_id"
            )
        }

        let endpoint = OpenAIRealtimeSpeechSessionEndpoint(
            configuration: configuration,
            targetLanguage: targetLanguage.value,
            transport: transportFactory(),
            initialSegmentRawValue: initialSegmentRawValue
        ) { [weak self] endpoint in
            self?.removeEndpointIfCurrent(endpoint)
        }
        let replaced = endpoints.updateValue(endpoint, forKey: flowID)
        replaced?.replace()

        do {
            let channels = try await endpoint.start()
            guard endpoints[flowID] === endpoint else {
                endpoint.replace()
                throw Self.failure(
                    classification: .invalidSession,
                    type: "invalid_session",
                    code: "session_replaced"
                )
            }
            return channels
        } catch let failure as SpeechProviderFailure {
            removeEndpointIfCurrent(endpoint)
            throw failure
        } catch {
            preconditionFailure("Typed provider start produced another error")
        }
    }

    public func stopSession(_ sessionID: SpeechSessionID) async {
        guard let endpoint = endpoints[sessionID.audioFlowID],
              endpoint.sessionID == sessionID
        else { return }
        await endpoint.stopByConsumer()
    }

    private func removeEndpointIfCurrent(
        _ endpoint: OpenAIRealtimeSpeechSessionEndpoint
    ) {
        let flowID = endpoint.sessionID.audioFlowID
        guard endpoints[flowID] === endpoint else { return }
        endpoints.removeValue(forKey: flowID)
    }

    private nonisolated static func makeCapabilities()
        -> SpeechProviderCapabilities
    {
        let format: AudioStreamFormat
        do {
            format = try .monoPCM16(sampleRate: 24_000)
        } catch {
            preconditionFailure("Fixed OpenAI PCM format is invalid")
        }
        return SpeechProviderCapabilities(
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
    }

    fileprivate nonisolated static func failure(
        classification: SpeechProviderFailureClassification,
        type: String,
        code: String?
    ) -> SpeechProviderFailure {
        SpeechProviderFailure(
            classification: classification,
            type: makeIdentifier(type),
            code: code.map(makeIdentifier)
        )
    }

    private nonisolated static func makeIdentifier(
        _ value: String
    ) -> SpeechFailureIdentifier {
        do {
            return try SpeechFailureIdentifier(value)
        } catch {
            preconditionFailure("Fixed failure identifier is invalid")
        }
    }
}

@available(iOS 18, macOS 15, *)
@MainActor
private final class OpenAIRealtimeSpeechSessionEndpoint {
    private struct CorrelatedFailure: Equatable {
        let generation: UInt64
        let failure: SpeechProviderFailure
    }

    private enum State {
        case starting
        case active
        case terminal
    }

    private static let stagingLimit = 128

    let sessionID: SpeechSessionID

    private let configuration: SpeechSessionConfiguration
    private let targetLanguage: String
    private let transport: any OpenAIRealtimeSpeechSessionTransport
    private let events: AsyncStream<SpeechEvent>
    private let eventContinuation: AsyncStream<SpeechEvent>.Continuation
    private let onFinished: @MainActor @Sendable (
        OpenAIRealtimeSpeechSessionEndpoint
    ) -> Void
    private var mapper: OpenAIRealtimeSpeechEventMapper
    private var state = State.starting
    private var stagedEvents: [OpenAIRealtimeDecodedEvent] = []
    private var startingFailure: SpeechProviderFailure?
    private var audioChannels: OpenAIRealtimeAudioChannels?
    private var failureCorrelationGeneration: UInt64 = 0
    private var immediatelyCorrelatedFailure: CorrelatedFailure?

    init(
        configuration: SpeechSessionConfiguration,
        targetLanguage: String,
        transport: any OpenAIRealtimeSpeechSessionTransport,
        initialSegmentRawValue: UInt64,
        onFinished: @escaping @MainActor @Sendable (
            OpenAIRealtimeSpeechSessionEndpoint
        ) -> Void
    ) {
        self.configuration = configuration
        sessionID = configuration.sessionID
        self.targetLanguage = targetLanguage
        self.transport = transport
        self.onFinished = onFinished
        mapper = OpenAIRealtimeSpeechEventMapper(
            configuration: configuration,
            initialSegmentRawValue: initialSegmentRawValue
        )
        let stream = AsyncStream<SpeechEvent>.makeStream()
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func start() async throws(SpeechProviderFailure) -> SpeechSessionChannels {
        installCallbacks()

        let connectedChannels: OpenAIRealtimeAudioChannels
        do {
            connectedChannels = try await transport.connect(
                targetLanguage: targetLanguage,
                transcriptionRequested:
                    configuration.features.contains(.transcription),
                audioBinding: OpenAIRealtimeAudioBinding(
                    sessionID: configuration.sessionID
                ),
                includeDownlink: true
            )
        } catch let failure {
            let reportedFailure = startingFailure ?? failure
            if state != .terminal {
                terminateBeforeStart(failure: reportedFailure)
                transport.cancelImmediately()
            }
            throw reportedFailure
        }

        guard state == .starting, !Task.isCancelled else {
            connectedChannels.finish(
                uplinkError: .transportClosed,
                downlinkError: .transportClosed
            )
            transport.cancelImmediately()
            throw startingFailure ?? Self.connectionCancelledFailure
        }

        audioChannels = connectedChannels
        state = .active
        eventContinuation.yield(.sessionStarted(sessionID: sessionID))
        let replay = stagedEvents
        stagedEvents.removeAll(keepingCapacity: false)
        for event in replay {
            guard state == .active else { break }
            receiveActive(event)
        }
        guard state == .active else {
            throw startingFailure ?? Self.connectionClosedFailure
        }

        return SpeechSessionChannels(
            sessionID: sessionID,
            events: events,
            uplink: connectedChannels.sender,
            downlink: connectedChannels.receiver
        )
    }

    func replace() {
        guard state != .terminal else { return }
        if state == .starting {
            startingFailure = Self.connectionCancelledFailure
        }
        state = .terminal
        yield(mapper.finish(reason: .replaced))
        stagedEvents.removeAll(keepingCapacity: false)
        audioChannels?.finish(
            uplinkError: .staleFlow,
            downlinkError: .staleFlow
        )
        finishEventStreamAndDetach()
        transport.cancelImmediately()
    }

    func stopByConsumer() async {
        guard state != .terminal else { return }
        if state == .starting {
            startingFailure = Self.connectionCancelledFailure
            state = .terminal
            yield(mapper.finish(reason: .consumerRequested))
            stagedEvents.removeAll(keepingCapacity: false)
            finishEventStreamAndDetach()
            transport.cancelImmediately()
            return
        }

        state = .terminal
        audioChannels?.stopUplink(error: .transportClosed)
        yield(mapper.finish(reason: .consumerRequested))
        finishEventStreamAndDetach()

        let closeTask = Task { @MainActor [transport] in
            await transport.closeGracefully()
        }
        let outcome = await closeTask.value
        switch outcome {
        case .serverAcknowledged, .localGraceful:
            audioChannels?.finishDownlink(error: nil)
        case .localImmediate, .localForcedAfterTimeout, .waitCancelled, .failed:
            audioChannels?.finishDownlink(error: .transportClosed)
        }
        audioChannels = nil
    }

    private func installCallbacks() {
        transport.onEvent = { [weak self] event in
            self?.receive(event)
        }
        transport.onTerminal = { [weak self] failure in
            self?.transportTerminated(failure)
        }
    }

    private func receive(_ event: OpenAIRealtimeDecodedEvent) {
        switch state {
        case .starting:
            receiveStarting(event)
        case .active:
            receiveActive(event)
        case .terminal:
            return
        }
    }

    private func receiveStarting(_ event: OpenAIRealtimeDecodedEvent) {
        if event == .sessionClosed {
            startingFailure = Self.connectionClosedFailure
            state = .terminal
            stagedEvents.removeAll(keepingCapacity: false)
            eventContinuation.finish()
            detachCallbacks()
            onFinished(self)
            transport.cancelImmediately()
            return
        }
        guard stagedEvents.count < Self.stagingLimit else {
            let failure = Self.stagingOverflowFailure
            startingFailure = failure
            state = .terminal
            stagedEvents.removeAll(keepingCapacity: false)
            eventContinuation.finish()
            detachCallbacks()
            onFinished(self)
            transport.cancelImmediately()
            return
        }
        stagedEvents.append(event)
    }

    private func receiveActive(_ event: OpenAIRealtimeDecodedEvent) {
        guard state == .active else { return }
        if case let .providerFailure(failure) = event {
            failureCorrelationGeneration &+= 1
            let correlation = CorrelatedFailure(
                generation: failureCorrelationGeneration,
                failure: failure
            )
            immediatelyCorrelatedFailure = correlation
            Task { @MainActor [weak self] in
                await Task.yield()
                guard self?.immediatelyCorrelatedFailure == correlation else {
                    return
                }
                self?.immediatelyCorrelatedFailure = nil
            }
        } else {
            immediatelyCorrelatedFailure = nil
        }
        let mapped = mapper.map(event)
        yield(mapped)
        guard let endReason = mapped.compactMap(Self.endReason).last else {
            return
        }
        finishMappedTerminal(reason: endReason)
    }

    private func transportTerminated(_ failure: SpeechProviderFailure) {
        switch state {
        case .starting:
            return
        case .active:
            if immediatelyCorrelatedFailure?.failure != failure {
                yield(mapper.map(.providerFailure(failure)))
            }
            immediatelyCorrelatedFailure = nil
            yield(mapper.finish(reason: .failed))
            finishAudioAndLifecycle(
                uplinkError: .transportClosed,
                downlinkError: .transportClosed
            )
        case .terminal:
            return
        }
    }

    private func finishMappedTerminal(reason: SpeechSessionEndReason) {
        let downlinkError: OpenAIRealtimeAudioChannelError? =
            reason == .completed ? nil : .transportClosed
        finishAudioAndLifecycle(
            uplinkError: .transportClosed,
            downlinkError: downlinkError
        )
        if reason == .failed {
            transport.cancelImmediately()
        }
    }

    private func finishAudioAndLifecycle(
        uplinkError: OpenAIRealtimeAudioChannelError,
        downlinkError: OpenAIRealtimeAudioChannelError?
    ) {
        guard state == .active else { return }
        state = .terminal
        audioChannels?.finish(
            uplinkError: uplinkError,
            downlinkError: downlinkError
        )
        audioChannels = nil
        finishEventStreamAndDetach()
    }

    private func terminateBeforeStart(failure: SpeechProviderFailure) {
        guard state == .starting else { return }
        startingFailure = failure
        state = .terminal
        stagedEvents.removeAll(keepingCapacity: false)
        eventContinuation.finish()
        detachCallbacks()
        onFinished(self)
    }

    private func finishEventStreamAndDetach() {
        eventContinuation.finish()
        detachCallbacks()
        onFinished(self)
    }

    private func detachCallbacks() {
        transport.onEvent = nil
        transport.onTerminal = nil
    }

    private func yield(_ events: [SpeechEvent]) {
        for event in events {
            eventContinuation.yield(event)
        }
    }

    private nonisolated static func endReason(
        _ event: SpeechEvent
    ) -> SpeechSessionEndReason? {
        guard case let .sessionEnded(_, reason) = event else { return nil }
        return reason
    }

    private nonisolated static let connectionCancelledFailure =
        OpenAIRealtimeSpeechProvider.failure(
            classification: .network,
            type: "network_error",
            code: "connection_cancelled"
        )

    private nonisolated static let connectionClosedFailure =
        OpenAIRealtimeSpeechProvider.failure(
            classification: .network,
            type: "network_error",
            code: "connection_closed"
        )

    private nonisolated static let stagingOverflowFailure =
        OpenAIRealtimeSpeechProvider.failure(
            classification: .provider,
            type: "provider_error",
            code: "event_staging_overflow"
        )
}
