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
@MainActor
final class OpenAIRealtimeWebSocketTransport {
    typealias ConnectionFactory = @MainActor (URLRequest)
        -> any OpenAIRealtimeWebSocketConnection
    typealias PostUpdateValidationHook = @MainActor @Sendable () async -> Void

    static let openTimeout: Duration = .seconds(12)

    var onEvent: (
        @MainActor @Sendable (OpenAIRealtimeDecodedEvent) -> Void
    )?

    private let authorization: OpenAIRealtimeAuthorization
    private let wireCodec: OpenAIRealtimeWireCodec
    private let connectionFactory: ConnectionFactory
    private let scheduler: any OpenAIRealtimeScheduler
    private let postUpdateValidationHook: PostUpdateValidationHook?
    private var connection: (any OpenAIRealtimeWebSocketConnection)?
    private var openContinuation:
        CheckedContinuation<Result<Void, SpeechProviderFailure>, Never>?
    private var updateContinuation:
        CheckedContinuation<Result<Void, SpeechProviderFailure>, Never>?
    private var openTimeoutTask: (any OpenAIRealtimeScheduledTask)?
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var pendingPostUpdateValidationGeneration: UInt64?
    private var terminalAfterSuccessfulUpdateGeneration: UInt64?
    private var isOpen = false
    private var isConnected = false
    private var isCancelled = false

    init(
        authorization: OpenAIRealtimeAuthorization,
        wireCodec: OpenAIRealtimeWireCodec = OpenAIRealtimeWireCodec(),
        connectionFactory: ConnectionFactory? = nil,
        scheduler: (any OpenAIRealtimeScheduler)? = nil,
        postUpdateValidationHook: PostUpdateValidationHook? = nil
    ) {
        self.authorization = authorization
        self.wireCodec = wireCodec
        self.connectionFactory = connectionFactory ?? { request in
            URLSessionRealtimeWebSocketConnection(request: request)
        }
        self.scheduler = scheduler ?? TaskRealtimeScheduler()
        self.postUpdateValidationHook = postUpdateValidationHook
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

    func cancelImmediately() {
        guard activeGeneration != nil || connection != nil else { return }
        let failure = Self.failure(
            classification: .network,
            type: "network_error",
            code: "connection_cancelled"
        )
        finishOpen(with: .failure(failure))
        finishUpdate(with: .failure(failure))
        terminateConnection()
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
        connection.onClose = { [weak self] _ in
            self?.socketDidClose(generation: generation)
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
            onEvent?(wireCodec.decode(message))
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

    private func socketDidClose(generation: UInt64) {
        guard activeGeneration == generation,
              !isCancelled
        else { return }
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
        let failure = Self.failure(
            classification: .network,
            type: "network_error",
            code: "connection_cancelled"
        )
        finishOpen(with: .failure(failure))
        finishUpdate(with: .failure(failure))
        terminateConnection()
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
