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

@available(iOS 18, macOS 13, *)
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

    private let authorization: OpenAIRealtimeAuthorization
    private let wireCodec: OpenAIRealtimeWireCodec
    private let connectionFactory: ConnectionFactory
    private let scheduler: any OpenAIRealtimeScheduler
    private let postUpdateValidationHook: PostUpdateValidationHook?
    private let closeWaiterCancellationHook: CloseWaiterCancellationHook?
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
    private var activeGeneration: UInt64?
    private var pendingPingAttemptGeneration: UInt64?
    private var closeGeneration: UInt64?
    private var activeCloseAttemptGeneration: UInt64?
    private var pendingPostUpdateValidationGeneration: UInt64?
    private var terminalAfterSuccessfulUpdateGeneration: UInt64?
    private var closeOutcome: OpenAIRealtimeCloseOutcome?
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
        closeWaiterCancellationHook: CloseWaiterCancellationHook? = nil
    ) {
        self.authorization = authorization
        self.wireCodec = wireCodec
        self.connectionFactory = connectionFactory ?? { request in
            URLSessionRealtimeWebSocketConnection(request: request)
        }
        self.scheduler = scheduler ?? TaskRealtimeScheduler()
        self.postUpdateValidationHook = postUpdateValidationHook
        self.closeWaiterCancellationHook = closeWaiterCancellationHook
    }

    func connect(
        targetLanguage: String,
        transcriptionRequested: Bool
    ) async throws(SpeechProviderFailure) {
        generation &+= 1
        let connectionGeneration = generation
        let result: Result<Void, SpeechProviderFailure> =
            await withTaskCancellationHandler {
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
                    generation: connectionGeneration
                )
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelForCaller(
                        generation: connectionGeneration
                    )
                }
            }
        try result.get()
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
        generation currentGeneration: UInt64
    ) async -> Result<Void, SpeechProviderFailure> {
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
        guard case .success = openResult else {
            terminateConnection(generation: currentGeneration)
            return openResult
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
                        generation: currentGeneration
                    )
                }
            }
        guard case .success = updateResult else {
            terminateConnection(generation: currentGeneration)
            return updateResult
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
            isCancelled = false
            return .success(())
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
        return .success(())
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
            let event = wireCodec.decode(message)
            onEvent?(event)
            if event == .sessionClosed {
                if closeGeneration == generation {
                    finishGracefulClose(
                        with: .serverAcknowledged,
                        terminate: true
                    )
                } else {
                    terminateConnection(generation: generation)
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
        generation: UInt64
    ) {
        guard activeGeneration == generation,
              !isCancelled,
              updateContinuation != nil
        else { return }
        if error == nil {
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
    }

    private func terminateSocketPreservingGeneration(_ generation: UInt64) {
        guard activeGeneration == generation else { return }
        cancelPingTasks()
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
                    generation: currentGeneration
                )
            }
        }
    }

    private func gracefulCloseSendCompleted(
        succeeded: Bool,
        generation: UInt64
    ) {
        guard closeOutcome == nil,
              closeGeneration == generation,
              activeGeneration == generation
        else { return }
        guard succeeded else {
            finishGracefulClose(with: .failed, terminate: true)
            return
        }
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
        let waiters = Array(closeWaiters.values)
        closeWaiters.removeAll(keepingCapacity: false)
        if terminate {
            terminateConnection()
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

    private func terminateConnection(generation: UInt64? = nil) {
        if let generation, activeGeneration != generation { return }
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        cancelPingTasks()
        closeDrainTimeoutTask?.cancel()
        closeDrainTimeoutTask = nil
        if let connection {
            connection.onOpen = nil
            connection.onMessage = nil
            connection.onClose = nil
            connection.cancel()
        }
        connection = nil
        activeGeneration = nil
        pendingPostUpdateValidationGeneration = nil
        terminalAfterSuccessfulUpdateGeneration = nil
        isOpen = false
        isConnected = false
        isCancelled = true
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
