import BabylonAudio
import BabylonSpeech
import Foundation

/// An OpenAI Realtime provider for provider-neutral speech translation.
///
/// Sessions require translation and a target language, use automatic source
/// language detection, and may additionally request transcription. Input and
/// translated output audio use 24 kHz mono PCM16. The application owns
/// authorization delivery, recovery policy, and provider recreation.
@available(iOS 18, macOS 15, *)
@MainActor
public final class OpenAIRealtimeSpeechProvider: SpeechProvider {
    typealias TransportFactory = @MainActor @Sendable ()
        -> any OpenAIRealtimeSpeechSessionTransport
    typealias PostStopResultHook = @MainActor @Sendable () async -> Void

    /// The fixed S2 OpenAI Realtime feature, authorization, and audio contract.
    ///
    /// The provider requires network access and caller-injected authorization,
    /// requires translation, optionally supports transcription, accepts only
    /// automatic source language, and uses 24 kHz mono PCM16 in both directions.
    public nonisolated let capabilities: SpeechProviderCapabilities

    private let transportFactory: TransportFactory
    private let initialSegmentRawValue: UInt64
    private let postStopResultHook: PostStopResultHook?
    private var endpoints: [AudioFlowID: OpenAIRealtimeSpeechSessionEndpoint]
        = [:]

    /// Creates a provider with caller-injected Realtime authorization.
    ///
    /// This initializer does not connect or start a session. Create a new
    /// provider when the application supplies replacement authorization.
    ///
    /// - Parameters:
    ///   - authorization: An app-owned, short-lived Realtime client secret
    ///     wrapper.
    ///   - transferObserver: An optional synchronous observer for content-free
    ///     application-payload byte facts.
    ///   - audioTransferObserver: An optional synchronous observer for
    ///     content-free audio media-duration facts.
    public init(
        authorization: OpenAIRealtimeAuthorization,
        transferObserver: OpenAIRealtimeTransferObserver? = nil,
        audioTransferObserver: OpenAIRealtimeAudioTransferObserver? = nil
    ) {
        capabilities = Self.makeCapabilities()
        initialSegmentRawValue = 0
        postStopResultHook = nil
        transportFactory = {
            OpenAIRealtimeWebSocketTransport(
                authorization: authorization,
                transferObserver: transferObserver,
                audioTransferObserver: audioTransferObserver
            )
        }
    }

    init(
        authorization: OpenAIRealtimeAuthorization,
        transportFactory: @escaping TransportFactory,
        initialSegmentRawValue: UInt64 = 0,
        postStopResultHook: PostStopResultHook? = nil
    ) {
        _ = authorization
        capabilities = Self.makeCapabilities()
        self.transportFactory = transportFactory
        self.initialSegmentRawValue = initialSegmentRawValue
        self.postStopResultHook = postStopResultHook
    }

    /// Starts an OpenAI Realtime translation session.
    ///
    /// The method returns channels after the WebSocket opens and the
    /// `session.update` send completion succeeds. It does not wait for or imply
    /// a separate server acknowledgement. Unsupported configurations and
    /// connection failures fail closed with safe, structured identifiers.
    ///
    /// - Parameter configuration: A translation configuration with automatic
    ///   source language and a target language. Transcription is optional.
    /// - Returns: Session-bound events, PCM uplink, and translated-audio downlink.
    /// - Throws: A safe ``SpeechProviderFailure``.
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
            initialSegmentRawValue: initialSegmentRawValue,
            postStopResultHook: postStopResultHook
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

    /// Stops the current matching session using the requested close mode.
    ///
    /// Unknown or stale session identifiers have no effect. The application
    /// remains responsible for any subsequent session or provider creation.
    ///
    /// - Parameters:
    ///   - sessionID: The exact session identity to stop.
    ///   - mode: Graceful drain or immediate transport cancellation.
    /// - Returns: The content-free terminal stop outcome.
    public func stopSession(
        _ sessionID: SpeechSessionID,
        mode: SpeechSessionStopMode
    ) async -> SpeechSessionStopOutcome {
        guard let endpoint = endpoints[sessionID.audioFlowID],
              endpoint.sessionID == sessionID
        else { return .noMatchingSession }
        return await endpoint.stopByConsumer(mode: mode)
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
        case stopping
        case terminal
    }

    private static let stagingLimit = 128

    let sessionID: SpeechSessionID

    private let configuration: SpeechSessionConfiguration
    private let targetLanguage: String
    private let transport: any OpenAIRealtimeSpeechSessionTransport
    private let events: AsyncStream<SpeechEvent>
    private let eventContinuation: AsyncStream<SpeechEvent>.Continuation
    private let postStopResultHook:
        OpenAIRealtimeSpeechProvider.PostStopResultHook?
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
    private var stopTask: Task<SpeechSessionStopOutcome, Never>?
    private var stopOutcome: SpeechSessionStopOutcome?
    private var didFinishLifecycle = false
    private var didRequestImmediateCancel = false

    init(
        configuration: SpeechSessionConfiguration,
        targetLanguage: String,
        transport: any OpenAIRealtimeSpeechSessionTransport,
        initialSegmentRawValue: UInt64,
        postStopResultHook:
            OpenAIRealtimeSpeechProvider.PostStopResultHook?,
        onFinished: @escaping @MainActor @Sendable (
            OpenAIRealtimeSpeechSessionEndpoint
        ) -> Void
    ) {
        self.configuration = configuration
        sessionID = configuration.sessionID
        self.targetLanguage = targetLanguage
        self.transport = transport
        self.postStopResultHook = postStopResultHook
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
                requestImmediateCancelOnce()
            }
            throw reportedFailure
        }

        guard state == .starting, !Task.isCancelled else {
            connectedChannels.finish(
                uplinkError: .transportClosed,
                downlinkError: .transportClosed
            )
            requestImmediateCancelOnce()
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
        switch state {
        case .terminal:
            return
        case .stopping:
            lockImmediateStop(channelError: .staleFlow)
            return
        case .starting:
            startingFailure = Self.connectionCancelledFailure
        case .active:
            break
        }
        state = .terminal
        yield(mapper.finish(reason: .replaced))
        stagedEvents.removeAll(keepingCapacity: false)
        audioChannels?.finish(
            uplinkError: .staleFlow,
            downlinkError: .staleFlow
        )
        finishEventStreamAndDetach()
        requestImmediateCancelOnce()
    }

    func stopByConsumer(
        mode: SpeechSessionStopMode
    ) async -> SpeechSessionStopOutcome {
        switch state {
        case .terminal:
            return stopOutcome ?? .noMatchingSession
        case .stopping:
            return await joinStop(mode: mode)
        case .starting:
            startingFailure = Self.connectionCancelledFailure
            state = .terminal
            stopOutcome = .immediate
            yield(mapper.finish(reason: .consumerRequested))
            stagedEvents.removeAll(keepingCapacity: false)
            finishEventStreamAndDetach()
            requestImmediateCancelOnce()
            return .immediate
        case .active:
            break
        }

        yield(mapper.finish(reason: .consumerRequested))
        if mode == .immediate {
            state = .terminal
            stopOutcome = .immediate
            audioChannels?.finish(
                uplinkError: .transportClosed,
                downlinkError: .transportClosed
            )
            audioChannels = nil
            finishEventStreamAndDetach()
            requestImmediateCancelOnce()
            return .immediate
        }

        state = .stopping
        audioChannels?.stopUplink(error: .transportClosed)
        finishEventStreamForStop()

        let closeTask = Task {
            @MainActor [transport, postStopResultHook] in
            let outcome = Self.stopOutcome(
                for: await transport.closeGracefully()
            )
            if let postStopResultHook {
                await postStopResultHook()
            }
            return outcome
        }
        stopTask = closeTask
        return completeStop(with: await closeTask.value)
    }

    private func joinStop(
        mode: SpeechSessionStopMode
    ) async -> SpeechSessionStopOutcome {
        guard let stopTask else {
            return stopOutcome ?? .failed
        }
        if mode == .immediate {
            lockImmediateStop(channelError: .transportClosed)
        }
        return completeStop(with: await stopTask.value)
    }

    private func completeStop(
        with outcome: SpeechSessionStopOutcome
    ) -> SpeechSessionStopOutcome {
        let resolvedOutcome = stopOutcome ?? outcome
        if stopOutcome == nil {
            stopOutcome = outcome
            state = .terminal
            switch outcome {
            case .graceful:
                audioChannels?.finishDownlink(error: nil)
            case .immediate, .forced, .failed, .noMatchingSession:
                audioChannels?.finishDownlink(error: .transportClosed)
            }
            audioChannels = nil
        }
        stopTask = nil
        notifyFinishedOnce()
        return resolvedOutcome
    }

    private func lockImmediateStop(
        channelError: OpenAIRealtimeAudioChannelError
    ) {
        if stopOutcome == nil {
            stopOutcome = .immediate
            state = .terminal
            audioChannels?.finish(
                uplinkError: channelError,
                downlinkError: channelError
            )
            audioChannels = nil
            finishEventStreamAndDetach()
        }
        requestImmediateCancelOnce()
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
        case .stopping, .terminal:
            return
        }
    }

    private func receiveStarting(_ event: OpenAIRealtimeDecodedEvent) {
        if event == .sessionClosed {
            startingFailure = Self.connectionClosedFailure
            state = .terminal
            stagedEvents.removeAll(keepingCapacity: false)
            finishEventStreamAndDetach()
            requestImmediateCancelOnce()
            return
        }
        guard stagedEvents.count < Self.stagingLimit else {
            let failure = Self.stagingOverflowFailure
            startingFailure = failure
            state = .terminal
            stagedEvents.removeAll(keepingCapacity: false)
            finishEventStreamAndDetach()
            requestImmediateCancelOnce()
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
        case .stopping, .terminal:
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
            requestImmediateCancelOnce()
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
        finishEventStreamAndDetach()
    }

    private func finishEventStreamAndDetach() {
        eventContinuation.finish()
        detachCallbacks()
        notifyFinishedOnce()
    }

    private func finishEventStreamForStop() {
        eventContinuation.finish()
        detachCallbacks()
    }

    private func detachCallbacks() {
        transport.onEvent = nil
        transport.onTerminal = nil
    }

    private func notifyFinishedOnce() {
        guard !didFinishLifecycle else { return }
        didFinishLifecycle = true
        onFinished(self)
    }

    private func requestImmediateCancelOnce() {
        guard !didRequestImmediateCancel else { return }
        didRequestImmediateCancel = true
        transport.cancelImmediately()
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

    private nonisolated static func stopOutcome(
        for outcome: OpenAIRealtimeCloseOutcome
    ) -> SpeechSessionStopOutcome {
        switch outcome {
        case .serverAcknowledged, .localGraceful:
            .graceful
        case .localImmediate:
            .immediate
        case .localForcedAfterTimeout:
            .forced
        case .waitCancelled, .failed:
            .failed
        }
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
