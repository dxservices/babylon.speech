import BabylonAudio
import BabylonSpeech
import Foundation

@available(iOS 18, macOS 13, *)
@MainActor
protocol OpenAIRealtimeScheduledTask: AnyObject, Sendable {
    func cancel()
}

@available(iOS 18, macOS 13, *)
@MainActor
protocol OpenAIRealtimeScheduler: AnyObject, Sendable {
    func schedule(
        after delay: Duration,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any OpenAIRealtimeScheduledTask
}

@available(iOS 18, macOS 13, *)
@MainActor
private final class TaskRealtimeScheduledTask:
    OpenAIRealtimeScheduledTask
{
    private var task: Task<Void, Never>?

    init(
        delay: Duration,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        task = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

@available(iOS 18, macOS 13, *)
@MainActor
private final class TaskRealtimeScheduler: OpenAIRealtimeScheduler {
    func schedule(
        after delay: Duration,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any OpenAIRealtimeScheduledTask {
        TaskRealtimeScheduledTask(delay: delay, action: action)
    }
}

@available(iOS 18, macOS 13, *)
enum OpenAIRealtimeCloseOutcome: Equatable, Sendable {
    case serverAcknowledged
    case localGraceful
    case localImmediate
    case localForcedAfterTimeout
    case waitCancelled
    case failed
}

@available(iOS 18, macOS 15, *)
@MainActor
final class OpenAIRealtimeWebSocketTransport {
    typealias ConnectionFactory = @MainActor (URLRequest)
        -> any OpenAIRealtimeWebSocketConnection
    typealias PostUpdateValidationHook = @MainActor @Sendable () async -> Void
    typealias CloseWaiterCancellationAction =
        @MainActor @Sendable () -> Void
    typealias CloseWaiterCancellationHook =
        @MainActor @Sendable (
            @escaping CloseWaiterCancellationAction
        ) async -> Void
    typealias UplinkSendCancellationAction =
        @MainActor @Sendable () -> Void
    typealias UplinkSendCancellationHook =
        @MainActor @Sendable (
            @escaping UplinkSendCancellationAction
        ) async -> Void

    private struct AudioRequest {
        let binding: OpenAIRealtimeAudioBinding
        let includeDownlink: Bool
    }

    private struct AudioEpoch {
        let binding: OpenAIRealtimeAudioBinding
        let connectionGeneration: UInt64
        let epochGeneration: UInt64
        let channels: OpenAIRealtimeAudioChannels
    }

    private struct TransferEpoch {
        let sessionID: SpeechSessionID
        let connectionGeneration: UInt64
    }

    private struct PendingUplink {
        let connectionGeneration: UInt64
        let epochGeneration: UInt64
        let attemptGeneration: UInt64
        let continuation: CheckedContinuation<
            Result<Void, OpenAIRealtimeAudioChannelError>,
            Never
        >
    }

    private struct PendingUplinkTransfer {
        let connectionGeneration: UInt64
        let epochGeneration: UInt64
        let attemptGeneration: UInt64
        let applicationPayloadBytes: Int64
        let audioDuration: Duration
    }

    private struct CloseWaiter {
        let connectionGeneration: UInt64
        let closeAttemptGeneration: UInt64
        let continuation:
            CheckedContinuation<OpenAIRealtimeCloseOutcome, Never>
    }

    static let openTimeout: Duration = .seconds(12)
    static let pingInterval: Duration = .seconds(15)
    static let pingResponseTimeout: Duration = .seconds(10)
    static let closeDrainTimeout: Duration = .seconds(10)

    var onEvent: (
        @MainActor @Sendable (OpenAIRealtimeDecodedEvent) -> Void
    )?
    var onTerminal: (
        @MainActor @Sendable (SpeechProviderFailure) -> Void
    )?

    private let authorization: OpenAIRealtimeAuthorization
    private let wireCodec: OpenAIRealtimeWireCodec
    private let connectionFactory: ConnectionFactory
    private let scheduler: any OpenAIRealtimeScheduler
    private let postUpdateValidationHook: PostUpdateValidationHook?
    private let closeWaiterCancellationHook: CloseWaiterCancellationHook?
    private let uplinkSendCancellationHook: UplinkSendCancellationHook?
    private let transferObserver: OpenAIRealtimeTransferObserver?
    private let audioTransferObserver: OpenAIRealtimeAudioTransferObserver?
    private var connection: (any OpenAIRealtimeWebSocketConnection)?
    private var openContinuation:
        CheckedContinuation<Result<Void, SpeechProviderFailure>, Never>?
    private var updateContinuation:
        CheckedContinuation<Result<Void, SpeechProviderFailure>, Never>?
    private var openTimeoutTask: (any OpenAIRealtimeScheduledTask)?
    private var pingIntervalTask: (any OpenAIRealtimeScheduledTask)?
    private var pingResponseTimeoutTask: (any OpenAIRealtimeScheduledTask)?
    private var closeDrainTimeoutTask: (any OpenAIRealtimeScheduledTask)?
    private var closeWaiters: [UInt64: CloseWaiter] = [:]
    private var generation: UInt64 = 0
    private var pingAttemptGeneration: UInt64 = 0
    private var closeAttemptGeneration: UInt64 = 0
    private var closeWaiterGeneration: UInt64 = 0
    private var audioEpochGeneration: UInt64 = 0
    private var uplinkAttemptGeneration: UInt64 = 0
    private var terminalSignalGeneration: UInt64?
    private var activeGeneration: UInt64?
    private var pendingPingAttemptGeneration: UInt64?
    private var closeGeneration: UInt64?
    private var activeCloseAttemptGeneration: UInt64?
    private var pendingPostUpdateValidationGeneration: UInt64?
    private var terminalAfterSuccessfulUpdateGeneration: UInt64?
    private var closeOutcome: OpenAIRealtimeCloseOutcome?
    private var audioEpoch: AudioEpoch?
    private var transferEpoch: TransferEpoch?
    private var pendingUplink: PendingUplink?
    private var pendingUplinkTransfer: PendingUplinkTransfer?
    private var consecutivePongFailures = 0
    private var isOpen = false
    private var isConnected = false
    private var isCancelled = false
    private var isGracefulCloseDraining = false

    init(
        authorization: OpenAIRealtimeAuthorization,
        wireCodec: OpenAIRealtimeWireCodec = OpenAIRealtimeWireCodec(),
        connectionFactory: ConnectionFactory? = nil,
        scheduler: (any OpenAIRealtimeScheduler)? = nil,
        postUpdateValidationHook: PostUpdateValidationHook? = nil,
        closeWaiterCancellationHook: CloseWaiterCancellationHook? = nil,
        uplinkSendCancellationHook: UplinkSendCancellationHook? = nil,
        transferObserver: OpenAIRealtimeTransferObserver? = nil,
        audioTransferObserver: OpenAIRealtimeAudioTransferObserver? = nil
    ) {
        self.authorization = authorization
        self.wireCodec = wireCodec
        self.connectionFactory = connectionFactory ?? { request in
            URLSessionRealtimeWebSocketConnection(request: request)
        }
        self.scheduler = scheduler ?? TaskRealtimeScheduler()
        self.postUpdateValidationHook = postUpdateValidationHook
        self.closeWaiterCancellationHook = closeWaiterCancellationHook
        self.uplinkSendCancellationHook = uplinkSendCancellationHook
        self.transferObserver = transferObserver
        self.audioTransferObserver = audioTransferObserver
    }

    func connect(
        targetLanguage: String,
        transcriptionRequested: Bool
    ) async throws(SpeechProviderFailure) {
        let result = await connectResult(
            targetLanguage: targetLanguage,
            transcriptionRequested: transcriptionRequested,
            audioRequest: nil
        )
        switch result {
        case .success:
            return
        case let .failure(failure):
            throw failure
        }
    }

    func connect(
        targetLanguage: String,
        transcriptionRequested: Bool,
        audioBinding: OpenAIRealtimeAudioBinding,
        includeDownlink: Bool
    ) async throws(SpeechProviderFailure) -> OpenAIRealtimeAudioChannels {
        let result = await connectResult(
            targetLanguage: targetLanguage,
            transcriptionRequested: transcriptionRequested,
            audioRequest: AudioRequest(
                binding: audioBinding,
                includeDownlink: includeDownlink
            )
        )
        switch result {
        case let .success(channels):
            guard let channels else {
                preconditionFailure("Audio connect completed without channels")
            }
            return channels
        case let .failure(failure):
            throw failure
        }
    }

    private func connectResult(
        targetLanguage: String,
        transcriptionRequested: Bool,
        audioRequest: AudioRequest?
    ) async -> Result<OpenAIRealtimeAudioChannels?, SpeechProviderFailure> {
        generation &+= 1
        let connectionGeneration = generation
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                return .failure(Self.failure(
                    classification: .network,
                    type: "network_error",
                    code: "connection_cancelled"
                ))
            }
            return await beginConnect(
                targetLanguage: targetLanguage,
                transcriptionRequested: transcriptionRequested,
                audioRequest: audioRequest,
                generation: connectionGeneration
            )
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelForCaller(
                    generation: connectionGeneration
                )
            }
        }
    }

    func sendPCM16(
        binding: OpenAIRealtimeAudioBinding,
        payload: Data
    ) async throws(OpenAIRealtimeAudioChannelError) {
        guard let audioEpoch else {
            throw .transportClosed
        }
        try await sendPCM16(
            binding: binding,
            payload: payload,
            connectionGeneration: audioEpoch.connectionGeneration,
            epochGeneration: audioEpoch.epochGeneration
        )
    }

    private func sendPCM16(
        binding: OpenAIRealtimeAudioBinding,
        payload: Data,
        connectionGeneration: UInt64,
        epochGeneration: UInt64
    ) async throws(OpenAIRealtimeAudioChannelError) {
        uplinkAttemptGeneration &+= 1
        let attemptGeneration = uplinkAttemptGeneration
        let result: Result<Void, OpenAIRealtimeAudioChannelError> =
            await withTaskCancellationHandler {
                guard !Task.isCancelled else {
                    return .failure(.sendCancelled)
                }
                return await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(
                            returning: .failure(.sendCancelled)
                        )
                        return
                    }
                    startUplink(
                        binding: binding,
                        payload: payload,
                        connectionGeneration: connectionGeneration,
                        epochGeneration: epochGeneration,
                        attemptGeneration: attemptGeneration,
                        continuation: continuation
                    )
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let action: UplinkSendCancellationAction = {
                        [weak self] in
                        self?.finishUplink(
                            with: .failure(.sendCancelled),
                            connectionGeneration: connectionGeneration,
                            epochGeneration: epochGeneration,
                            attemptGeneration: attemptGeneration,
                            invalidateTransfer: true
                        )
                    }
                    if let uplinkSendCancellationHook {
                        await uplinkSendCancellationHook(action)
                    } else {
                        action()
                    }
                }
            }
        switch result {
        case .success:
            return
        case let .failure(error):
            throw error
        }
    }

    private func startUplink(
        binding: OpenAIRealtimeAudioBinding,
        payload: Data,
        connectionGeneration: UInt64,
        epochGeneration: UInt64,
        attemptGeneration: UInt64,
        continuation: CheckedContinuation<
            Result<Void, OpenAIRealtimeAudioChannelError>,
            Never
        >
    ) {
        guard let audioEpoch else {
            continuation.resume(returning: .failure(.transportClosed))
            return
        }
        guard audioEpoch.binding == binding,
              audioEpoch.connectionGeneration == connectionGeneration,
              audioEpoch.epochGeneration == epochGeneration
        else {
            continuation.resume(returning: .failure(.staleFlow))
            return
        }
        guard activeGeneration == connectionGeneration,
              isOpen,
              isConnected,
              !isCancelled,
              !isGracefulCloseDraining,
              let connection
        else {
            continuation.resume(returning: .failure(.transportClosed))
            return
        }
        guard !payload.isEmpty,
              payload.count.isMultiple(of: MemoryLayout<Int16>.size)
        else {
            continuation.resume(
                returning: .failure(.invalidPCM16Payload)
            )
            return
        }
        guard let audioDuration = Self.audioDuration(
            forPCM16ByteCount: payload.count
        ) else {
            continuation.resume(
                returning: .failure(.invalidPCM16Payload)
            )
            return
        }
        guard let event = wireCodec.appendAudioEvent(
            pcm16Audio: payload
        ) else {
            continuation.resume(
                returning: .failure(.invalidPCM16Payload)
            )
            return
        }
        guard pendingUplink == nil else {
            continuation.resume(
                returning: .failure(.uplinkRelayOverflow)
            )
            return
        }

        pendingUplink = PendingUplink(
            connectionGeneration: connectionGeneration,
            epochGeneration: epochGeneration,
            attemptGeneration: attemptGeneration,
            continuation: continuation
        )
        pendingUplinkTransfer = PendingUplinkTransfer(
            connectionGeneration: connectionGeneration,
            epochGeneration: epochGeneration,
            attemptGeneration: attemptGeneration,
            applicationPayloadBytes: Int64(event.utf8.count),
            audioDuration: audioDuration
        )
        connection.send(text: event) { [weak self] error in
            self?.uplinkSendCompleted(
                succeeded: error == nil,
                connectionGeneration: connectionGeneration,
                epochGeneration: epochGeneration,
                attemptGeneration: attemptGeneration
            )
        }
    }

    private func finishUplink(
        with result: Result<Void, OpenAIRealtimeAudioChannelError>,
        connectionGeneration: UInt64,
        epochGeneration: UInt64,
        attemptGeneration: UInt64,
        invalidateTransfer: Bool = false
    ) {
        if invalidateTransfer,
           pendingUplinkTransfer?.connectionGeneration
            == connectionGeneration,
           pendingUplinkTransfer?.epochGeneration == epochGeneration,
           pendingUplinkTransfer?.attemptGeneration == attemptGeneration
        {
            pendingUplinkTransfer = nil
        }
        guard let pendingUplink,
              pendingUplink.connectionGeneration == connectionGeneration,
              pendingUplink.epochGeneration == epochGeneration,
              pendingUplink.attemptGeneration == attemptGeneration
        else { return }
        self.pendingUplink = nil
        pendingUplink.continuation.resume(returning: result)
    }

    private func uplinkSendCompleted(
        succeeded: Bool,
        connectionGeneration: UInt64,
        epochGeneration: UInt64,
        attemptGeneration: UInt64
    ) {
        guard let transfer = pendingUplinkTransfer,
              transfer.connectionGeneration == connectionGeneration,
              transfer.epochGeneration == epochGeneration,
              transfer.attemptGeneration == attemptGeneration
        else { return }
        pendingUplinkTransfer = nil

        guard succeeded else {
            finishUplink(
                with: .failure(.sendFailed),
                connectionGeneration: connectionGeneration,
                epochGeneration: epochGeneration,
                attemptGeneration: attemptGeneration
            )
            return
        }
        guard reportTransferIfCurrent(
            direction: .uplink,
            applicationPayloadBytes: transfer.applicationPayloadBytes,
            generation: connectionGeneration
        ) else { return }
        guard reportAudioTransferIfCurrent(
            direction: .uplink,
            audioDuration: transfer.audioDuration,
            generation: connectionGeneration
        ) else { return }
        finishUplink(
            with: .success(()),
            connectionGeneration: connectionGeneration,
            epochGeneration: epochGeneration,
            attemptGeneration: attemptGeneration
        )
    }

    private func installAudioEpoch(
        request: AudioRequest,
        connectionGeneration: UInt64
    ) -> OpenAIRealtimeAudioChannels {
        audioEpochGeneration &+= 1
        let epochGeneration = audioEpochGeneration
        let channels = OpenAIRealtimeAudioChannels(
            binding: request.binding,
            sendPCM16: { [weak self] binding, payload in
                guard let self else {
                    throw OpenAIRealtimeAudioChannelError.transportClosed
                }
                try await self.sendPCM16(
                    binding: binding,
                    payload: payload,
                    connectionGeneration: connectionGeneration,
                    epochGeneration: epochGeneration
                )
            },
            includeReceiver: request.includeDownlink
        )
        audioEpoch = AudioEpoch(
            binding: request.binding,
            connectionGeneration: connectionGeneration,
            epochGeneration: epochGeneration,
            channels: channels
        )
        return channels
    }

    private func stopAudioUplink(
        error: OpenAIRealtimeAudioChannelError,
        retainsPendingTransfer: Bool = false
    ) {
        if !retainsPendingTransfer {
            pendingUplinkTransfer = nil
        }
        if let pendingUplink {
            finishUplink(
                with: .failure(error),
                connectionGeneration: pendingUplink.connectionGeneration,
                epochGeneration: pendingUplink.epochGeneration,
                attemptGeneration: pendingUplink.attemptGeneration
            )
        }
        audioEpoch?.channels.stopUplink(error: error)
    }

    private func finishAudioEpoch(
        uplinkError: OpenAIRealtimeAudioChannelError,
        downlinkError: OpenAIRealtimeAudioChannelError?
    ) {
        stopAudioUplink(error: uplinkError)
        audioEpoch?.channels.finishDownlink(error: downlinkError)
        audioEpoch = nil
    }

    @discardableResult
    func cancelImmediately() -> OpenAIRealtimeCloseOutcome {
        if closeOutcome == nil,
           closeGeneration != nil || !closeWaiters.isEmpty
        {
            finishGracefulClose(
                with: .localImmediate,
                terminate: false
            )
        }
        guard activeGeneration != nil || connection != nil else {
            return .localImmediate
        }
        let failure = Self.failure(
            classification: .network,
            type: "network_error",
            code: "connection_cancelled"
        )
        finishOpen(with: .failure(failure))
        finishUpdate(with: .failure(failure))
        terminateConnection()
        return .localImmediate
    }

    func closeGracefully() async -> OpenAIRealtimeCloseOutcome {
        if let closeOutcome {
            return closeOutcome
        }
        if Task.isCancelled {
            return .waitCancelled
        }

        closeWaiterGeneration &+= 1
        let waiterToken = closeWaiterGeneration
        let expectedConnectionGeneration = activeGeneration
        let expectedCloseAttemptGeneration =
            activeCloseAttemptGeneration ?? closeAttemptGeneration &+ 1

        return await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                return .waitCancelled
            }
            return await withCheckedContinuation { continuation in
                if let closeOutcome {
                    continuation.resume(returning: closeOutcome)
                    return
                }
                if Task.isCancelled {
                    continuation.resume(returning: .waitCancelled)
                    return
                }
                registerGracefulCloseWaiter(
                    token: waiterToken,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let action: CloseWaiterCancellationAction = {
                    [weak self] in
                    self?.cancelGracefulCloseWaiter(
                        token: waiterToken,
                        connectionGeneration: expectedConnectionGeneration,
                        closeAttemptGeneration:
                            expectedCloseAttemptGeneration
                    )
                }
                if let closeWaiterCancellationHook {
                    await closeWaiterCancellationHook(action)
                } else {
                    action()
                }
            }
        }
    }

    private func beginConnect(
        targetLanguage: String,
        transcriptionRequested: Bool,
        audioRequest: AudioRequest?,
        generation currentGeneration: UInt64
    ) async -> Result<OpenAIRealtimeAudioChannels?, SpeechProviderFailure> {
        guard let endpoint = wireCodec.websocketEndpoint else {
            return .failure(Self.failure(
                classification: .network,
                type: "network_error",
                code: "invalid_endpoint"
            ))
        }
        guard let updateEvent = wireCodec.sessionUpdateEvent(
            targetLanguage: targetLanguage,
            transcriptionRequested: transcriptionRequested
        ) else {
            return .failure(Self.failure(
                classification: .unsupportedConfiguration,
                type: "invalid_configuration",
                code: "target_language_required"
            ))
        }

        finishAudioEpoch(
            uplinkError: .staleFlow,
            downlinkError: .staleFlow
        )
        cancelImmediately()
        resetCloseStateForNewConnection()
        activeGeneration = currentGeneration
        isCancelled = false
        isOpen = false
        isConnected = false

        var request = URLRequest(url: endpoint)
        guard authorization.apply(to: &request) else {
            activeGeneration = nil
            return .failure(Self.failure(
                classification: .credential,
                type: "authentication_error",
                code: "invalid_client_secret"
            ))
        }
        transferEpoch = audioRequest.map {
            TransferEpoch(
                sessionID: $0.binding.sessionID,
                connectionGeneration: currentGeneration
            )
        }

        let connection = connectionFactory(request)
        self.connection = connection
        installCallbacks(
            on: connection,
            generation: currentGeneration
        )

        let openResult: Result<Void, SpeechProviderFailure> =
            await withCheckedContinuation { continuation in
                openContinuation = continuation
                openTimeoutTask = scheduler.schedule(
                    after: Self.openTimeout
                ) { [weak self] in
                    self?.openTimedOut(generation: currentGeneration)
                }
                connection.resume()
            }
        switch openResult {
        case .success:
            break
        case let .failure(failure):
            terminateConnection(generation: currentGeneration)
            return .failure(failure)
        }
        guard activeGeneration == currentGeneration,
              !isCancelled,
              isOpen
        else {
            terminateConnection(generation: currentGeneration)
            return .failure(Self.failure(
                classification: .network,
                type: "network_error",
                code: "connection_cancelled"
            ))
        }

        let updateResult: Result<Void, SpeechProviderFailure> =
            await withCheckedContinuation { continuation in
                updateContinuation = continuation
                connection.send(text: updateEvent) { [weak self] error in
                    self?.updateSendCompleted(
                        error: error,
                        generation: currentGeneration,
                        applicationPayloadBytes:
                            Int64(updateEvent.utf8.count)
                    )
                }
            }
        switch updateResult {
        case .success:
            break
        case let .failure(failure):
            terminateConnection(generation: currentGeneration)
            return .failure(failure)
        }
        if let postUpdateValidationHook {
            await postUpdateValidationHook()
        }
        guard activeGeneration == currentGeneration else {
            return .failure(Self.failure(
                classification: .network,
                type: "network_error",
                code: "connection_cancelled"
            ))
        }
        guard !Task.isCancelled else {
            terminateConnection(generation: currentGeneration)
            return .failure(Self.failure(
                classification: .network,
                type: "network_error",
                code: "connection_cancelled"
            ))
        }
        if terminalAfterSuccessfulUpdateGeneration == currentGeneration {
            pendingPostUpdateValidationGeneration = nil
            terminalAfterSuccessfulUpdateGeneration = nil
            activeGeneration = nil
            transferEpoch = nil
            isCancelled = false
            if audioRequest == nil {
                return .success(nil)
            }
            return .failure(Self.failure(
                classification: .network,
                type: "network_error",
                code: "connection_closed"
            ))
        }
        guard !isCancelled,
              isOpen,
              isConnected
        else {
            terminateConnection(generation: currentGeneration)
            return .failure(Self.failure(
                classification: .network,
                type: "network_error",
                code: "connection_cancelled"
            ))
        }

        pendingPostUpdateValidationGeneration = nil
        scheduleNextPing(generation: currentGeneration)
        guard let audioRequest else {
            return .success(nil)
        }
        return .success(installAudioEpoch(
            request: audioRequest,
            connectionGeneration: currentGeneration
        ))
    }

    private func installCallbacks(
        on connection: any OpenAIRealtimeWebSocketConnection,
        generation: UInt64
    ) {
        connection.onOpen = { [weak self] in
            self?.socketDidOpen(generation: generation)
        }
        connection.onMessage = { [weak self] result in
            self?.socketDidReceive(result, generation: generation)
        }
        connection.onClose = { [weak self] error in
            self?.socketDidClose(error: error, generation: generation)
        }
    }

    private func socketDidOpen(generation: UInt64) {
        guard activeGeneration == generation,
              !isCancelled,
              !isOpen
        else { return }
        isOpen = true
        finishOpen(with: .success(()))
    }

    private func socketDidReceive(
        _ result: Result<OpenAIRealtimeWebSocketMessage, any Error>,
        generation: UInt64
    ) {
        guard activeGeneration == generation,
              isConnected,
              !isCancelled
        else { return }

        switch result {
        case let .success(message):
            guard reportTransferIfCurrent(
                direction: .downlink,
                applicationPayloadBytes:
                    Self.applicationPayloadBytes(for: message),
                generation: generation
            ) else { return }
            let event = wireCodec.decode(message)
            switch event {
            case let .translatedAudio(payload):
                if let audioDuration = Self.audioDuration(
                    forPCM16ByteCount: payload.count
                ) {
                    guard reportAudioTransferIfCurrent(
                        direction: .downlink,
                        audioDuration: audioDuration,
                        generation: generation
                    ) else { return }
                }
                if let audioEpoch,
                   audioEpoch.connectionGeneration == generation
                {
                    let receiveResult = audioEpoch.channels.receiver?
                        .receivePCM16(payload)
                    if case let .failed(error) = receiveResult {
                        finishAudioEpoch(
                            uplinkError: error,
                            downlinkError: error
                        )
                    }
                }
            default:
                onEvent?(event)
            }
            if event == .sessionClosed {
                if closeGeneration == generation {
                    finishGracefulClose(
                        with: .serverAcknowledged,
                        terminate: true
                    )
                } else {
                    terminateConnection(
                        generation: generation,
                        downlinkError: nil
                    )
                }
                return
            }
            receiveNext(generation: generation)
        case .failure:
            handleEstablishedConnectionFailure(
                Self.failure(
                    classification: .network,
                    type: "network_error",
                    code: "connection_closed"
                ),
                generation: generation
            )
        }
    }

    private func socketDidClose(
        error: (any Error)?,
        generation: UInt64
    ) {
        guard activeGeneration == generation,
              !isCancelled
        else { return }
        if closeGeneration == generation,
           isGracefulCloseDraining,
           error == nil
        {
            finishGracefulClose(
                with: .localGraceful,
                terminate: true
            )
            return
        }
        let failure = Self.failure(
            classification: .network,
            type: "network_error",
            code: "connection_closed"
        )
        if openContinuation != nil {
            finishOpen(with: .failure(failure))
        } else if updateContinuation != nil {
            finishUpdate(with: .failure(failure))
        } else if isConnected {
            handleEstablishedConnectionFailure(
                failure,
                generation: generation
            )
            return
        }
        terminateConnection(generation: generation)
    }

    private func updateSendCompleted(
        error: (any Error)?,
        generation: UInt64,
        applicationPayloadBytes: Int64
    ) {
        guard activeGeneration == generation,
              !isCancelled,
              updateContinuation != nil
        else { return }
        if error == nil {
            guard reportTransferIfCurrent(
                direction: .uplink,
                applicationPayloadBytes: applicationPayloadBytes,
                generation: generation
            ) else { return }
            isConnected = true
            pendingPostUpdateValidationGeneration = generation
            finishUpdate(with: .success(()))
            receiveNext(generation: generation)
        } else {
            finishUpdate(with: .failure(Self.failure(
                classification: .network,
                type: "network_error",
                code: "session_update_failed"
            )))
        }
    }

    private func receiveNext(generation: UInt64) {
        guard activeGeneration == generation,
              isConnected,
              !isCancelled
        else { return }
        connection?.receive()
    }

    private func handleEstablishedConnectionFailure(
        _ failure: SpeechProviderFailure,
        generation: UInt64
    ) {
        let shouldSignalTerminal =
            pendingPostUpdateValidationGeneration != generation
            && closeGeneration != generation
        if closeGeneration == generation {
            finishGracefulClose(with: .failed, terminate: false)
        }
        onEvent?(.providerFailure(failure))
        if pendingPostUpdateValidationGeneration == generation {
            terminalAfterSuccessfulUpdateGeneration = generation
            terminateSocketPreservingGeneration(generation)
        } else {
            terminateConnection(generation: generation)
        }
        if shouldSignalTerminal {
            signalTerminal(failure, generation: generation)
        }
    }

    private func terminateSocketPreservingGeneration(_ generation: UInt64) {
        guard activeGeneration == generation else { return }
        finishAudioEpoch(
            uplinkError: .transportClosed,
            downlinkError: .transportClosed
        )
        cancelPingTasks()
        transferEpoch = nil
        pendingUplinkTransfer = nil
        if let connection {
            connection.onOpen = nil
            connection.onMessage = nil
            connection.onClose = nil
            connection.cancel()
        }
        connection = nil
        isOpen = false
        isConnected = false
    }

    private func openTimedOut(generation: UInt64) {
        guard activeGeneration == generation,
              openContinuation != nil
        else { return }
        finishOpen(with: .failure(Self.failure(
            classification: .network,
            type: "network_error",
            code: "connection_timed_out"
        )))
        terminateConnection(generation: generation)
    }

    private func cancelForCaller(generation: UInt64) {
        guard activeGeneration == generation else { return }
        if closeGeneration == generation {
            finishGracefulClose(
                with: .localImmediate,
                terminate: false
            )
        }
        let failure = Self.failure(
            classification: .network,
            type: "network_error",
            code: "connection_cancelled"
        )
        finishOpen(with: .failure(failure))
        finishUpdate(with: .failure(failure))
        terminateConnection()
    }

    private func scheduleNextPing(generation: UInt64) {
        guard activeGeneration == generation,
              isConnected,
              !isCancelled,
              !isGracefulCloseDraining,
              pendingPingAttemptGeneration == nil
        else { return }
        pingIntervalTask?.cancel()
        pingIntervalTask = scheduler.schedule(
            after: Self.pingInterval
        ) { [weak self] in
            self?.beginPing(generation: generation)
        }
    }

    private func beginPing(generation: UInt64) {
        guard activeGeneration == generation,
              isConnected,
              !isCancelled,
              !isGracefulCloseDraining,
              pendingPingAttemptGeneration == nil,
              let connection
        else { return }
        pingIntervalTask = nil
        pingAttemptGeneration &+= 1
        let attemptGeneration = pingAttemptGeneration
        pendingPingAttemptGeneration = attemptGeneration
        pingResponseTimeoutTask = scheduler.schedule(
            after: Self.pingResponseTimeout
        ) { [weak self] in
            self?.pingCompleted(
                succeeded: false,
                attemptGeneration: attemptGeneration,
                connectionGeneration: generation
            )
        }
        connection.sendPing { [weak self] error in
            self?.pingCompleted(
                succeeded: error == nil,
                attemptGeneration: attemptGeneration,
                connectionGeneration: generation
            )
        }
    }

    private func pingCompleted(
        succeeded: Bool,
        attemptGeneration: UInt64,
        connectionGeneration: UInt64
    ) {
        guard activeGeneration == connectionGeneration,
              pendingPingAttemptGeneration == attemptGeneration
        else { return }
        pendingPingAttemptGeneration = nil
        pingResponseTimeoutTask?.cancel()
        pingResponseTimeoutTask = nil

        if succeeded {
            consecutivePongFailures = 0
            scheduleNextPing(generation: connectionGeneration)
            return
        }

        consecutivePongFailures += 1
        guard consecutivePongFailures >= 2 else {
            scheduleNextPing(generation: connectionGeneration)
            return
        }
        handleEstablishedConnectionFailure(
            Self.failure(
                classification: .network,
                type: "network_error",
                code: "pong_unresponsive"
            ),
            generation: connectionGeneration
        )
    }

    private func cancelPingTasks() {
        pingIntervalTask?.cancel()
        pingIntervalTask = nil
        pingResponseTimeoutTask?.cancel()
        pingResponseTimeoutTask = nil
        pendingPingAttemptGeneration = nil
        consecutivePongFailures = 0
    }

    private func registerGracefulCloseWaiter(
        token: UInt64,
        continuation: CheckedContinuation<
            OpenAIRealtimeCloseOutcome,
            Never
        >
    ) {
        var connectionToSend:
            (any OpenAIRealtimeWebSocketConnection)?
        var closeEventToSend: String?

        if closeGeneration == nil {
            guard let currentGeneration = activeGeneration,
                  isConnected,
                  !isCancelled,
                  let connection
            else {
                finishGracefulClose(
                    with: .localImmediate,
                    terminate: false
                )
                cancelImmediately()
                continuation.resume(returning: .localImmediate)
                return
            }
            guard let closeEvent = wireCodec.sessionCloseEvent() else {
                finishGracefulClose(with: .failed, terminate: true)
                continuation.resume(returning: .failed)
                return
            }

            closeAttemptGeneration &+= 1
            let attemptGeneration = closeAttemptGeneration
            closeGeneration = currentGeneration
            activeCloseAttemptGeneration = attemptGeneration
            isGracefulCloseDraining = true
            stopAudioUplink(
                error: .transportClosed,
                retainsPendingTransfer: true
            )
            cancelPingTasks()
            closeDrainTimeoutTask = scheduler.schedule(
                after: Self.closeDrainTimeout
            ) { [weak self] in
                self?.gracefulCloseTimedOut(
                    generation: currentGeneration
                )
            }
            connectionToSend = connection
            closeEventToSend = closeEvent
        }

        guard let currentGeneration = closeGeneration,
              let attemptGeneration = activeCloseAttemptGeneration
        else {
            continuation.resume(returning: closeOutcome ?? .failed)
            return
        }
        closeWaiters[token] = CloseWaiter(
            connectionGeneration: currentGeneration,
            closeAttemptGeneration: attemptGeneration,
            continuation: continuation
        )

        if let connectionToSend,
           let closeEventToSend
        {
            connectionToSend.send(text: closeEventToSend) {
                [weak self] error in
                self?.gracefulCloseSendCompleted(
                    succeeded: error == nil,
                    generation: currentGeneration,
                    applicationPayloadBytes:
                        Int64(closeEventToSend.utf8.count)
                )
            }
        }
    }

    private func gracefulCloseSendCompleted(
        succeeded: Bool,
        generation: UInt64,
        applicationPayloadBytes: Int64
    ) {
        guard closeOutcome == nil,
              closeGeneration == generation,
              activeGeneration == generation
        else { return }
        guard succeeded else {
            finishGracefulClose(with: .failed, terminate: true)
            return
        }
        _ = reportTransferIfCurrent(
            direction: .uplink,
            applicationPayloadBytes: applicationPayloadBytes,
            generation: generation
        )
    }

    private func gracefulCloseTimedOut(generation: UInt64) {
        guard closeOutcome == nil,
              closeGeneration == generation,
              activeGeneration == generation,
              isGracefulCloseDraining
        else { return }
        finishGracefulClose(
            with: .localForcedAfterTimeout,
            terminate: true
        )
    }

    private func cancelGracefulCloseWaiter(
        token: UInt64,
        connectionGeneration: UInt64?,
        closeAttemptGeneration: UInt64
    ) {
        guard let connectionGeneration,
              let waiter = closeWaiters[token],
              waiter.connectionGeneration == connectionGeneration,
              waiter.closeAttemptGeneration == closeAttemptGeneration
        else { return }
        closeWaiters.removeValue(forKey: token)
        waiter.continuation.resume(returning: .waitCancelled)
    }

    private func finishGracefulClose(
        with outcome: OpenAIRealtimeCloseOutcome,
        terminate: Bool
    ) {
        guard closeOutcome == nil else { return }
        closeOutcome = outcome
        closeDrainTimeoutTask?.cancel()
        closeDrainTimeoutTask = nil
        closeGeneration = nil
        activeCloseAttemptGeneration = nil
        isGracefulCloseDraining = false
        transferEpoch = nil
        pendingUplinkTransfer = nil
        let waiters = Array(closeWaiters.values)
        closeWaiters.removeAll(keepingCapacity: false)
        if terminate {
            let downlinkError: OpenAIRealtimeAudioChannelError? =
                switch outcome {
                case .serverAcknowledged, .localGraceful:
                    nil
                default:
                    .transportClosed
                }
            terminateConnection(downlinkError: downlinkError)
        }
        for waiter in waiters {
            waiter.continuation.resume(returning: outcome)
        }
    }

    private func resetCloseStateForNewConnection() {
        closeDrainTimeoutTask?.cancel()
        closeDrainTimeoutTask = nil
        closeGeneration = nil
        activeCloseAttemptGeneration = nil
        closeOutcome = nil
        closeWaiters.removeAll(keepingCapacity: false)
        isGracefulCloseDraining = false
    }

    private func finishOpen(
        with result: Result<Void, SpeechProviderFailure>
    ) {
        guard let continuation = openContinuation else { return }
        openContinuation = nil
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        continuation.resume(returning: result)
    }

    private func finishUpdate(
        with result: Result<Void, SpeechProviderFailure>
    ) {
        guard let continuation = updateContinuation else { return }
        updateContinuation = nil
        continuation.resume(returning: result)
    }

    private func terminateConnection(
        generation: UInt64? = nil,
        downlinkError: OpenAIRealtimeAudioChannelError? = .transportClosed
    ) {
        if let generation, activeGeneration != generation { return }
        finishAudioEpoch(
            uplinkError: .transportClosed,
            downlinkError: downlinkError
        )
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        cancelPingTasks()
        closeDrainTimeoutTask?.cancel()
        closeDrainTimeoutTask = nil
        let connectionToCancel = connection
        connection = nil
        activeGeneration = nil
        transferEpoch = nil
        pendingUplinkTransfer = nil
        pendingPostUpdateValidationGeneration = nil
        terminalAfterSuccessfulUpdateGeneration = nil
        isOpen = false
        isConnected = false
        isCancelled = true
        connectionToCancel?.onOpen = nil
        connectionToCancel?.onMessage = nil
        connectionToCancel?.onClose = nil
        connectionToCancel?.cancel()
    }

    @discardableResult
    private func reportTransferIfCurrent(
        direction: OpenAIRealtimeTransferDirection,
        applicationPayloadBytes: Int64,
        generation: UInt64
    ) -> Bool {
        guard activeGeneration == generation,
              !isCancelled
        else { return false }
        let observedEpoch = transferEpoch
        if let observedEpoch,
           observedEpoch.connectionGeneration == generation,
           let transferObserver
        {
            transferObserver(
                observedEpoch.sessionID,
                OpenAIRealtimeTransferFact(
                    direction: direction,
                    applicationPayloadBytes: applicationPayloadBytes
                )
            )
        }
        guard activeGeneration == generation,
              !isCancelled
        else { return false }
        if let observedEpoch {
            guard let currentEpoch = transferEpoch,
                  currentEpoch.connectionGeneration
                    == observedEpoch.connectionGeneration,
                  currentEpoch.sessionID == observedEpoch.sessionID
            else { return false }
        }
        return true
    }

    @discardableResult
    private func reportAudioTransferIfCurrent(
        direction: OpenAIRealtimeTransferDirection,
        audioDuration: Duration,
        generation: UInt64
    ) -> Bool {
        guard activeGeneration == generation,
              !isCancelled
        else { return false }
        let observedEpoch = transferEpoch
        if let observedEpoch,
           observedEpoch.connectionGeneration == generation,
           let audioTransferObserver
        {
            audioTransferObserver(
                observedEpoch.sessionID,
                OpenAIRealtimeAudioTransferFact(
                    direction: direction,
                    audioDuration: audioDuration
                )
            )
        }
        guard activeGeneration == generation,
              !isCancelled
        else { return false }
        if let observedEpoch {
            guard let currentEpoch = transferEpoch,
                  currentEpoch.connectionGeneration
                    == observedEpoch.connectionGeneration,
                  currentEpoch.sessionID == observedEpoch.sessionID
            else { return false }
        }
        return true
    }

    nonisolated static func audioDuration(
        forPCM16ByteCount byteCount: Int
    ) -> Duration? {
        guard let format = try? AudioStreamFormat.monoPCM16(
            sampleRate: 24_000
        ) else { return nil }
        return try? format.duration(forPayloadByteCount: byteCount)
    }

    private nonisolated static func applicationPayloadBytes(
        for message: OpenAIRealtimeWebSocketMessage
    ) -> Int64 {
        switch message {
        case let .string(text):
            Int64(text.utf8.count)
        case let .data(data):
            Int64(data.count)
        }
    }

    private func signalTerminal(
        _ failure: SpeechProviderFailure,
        generation: UInt64
    ) {
        guard terminalSignalGeneration != generation else { return }
        terminalSignalGeneration = generation
        onTerminal?(failure)
    }

    private static func failure(
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

    private static func makeIdentifier(
        _ value: String
    ) -> SpeechFailureIdentifier {
        do {
            return try SpeechFailureIdentifier(value)
        } catch {
            preconditionFailure("Fixed failure identifier is invalid")
        }
    }
}
