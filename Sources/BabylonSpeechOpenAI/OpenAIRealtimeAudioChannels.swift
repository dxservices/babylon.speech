import BabylonAudio
import BabylonSpeech
import Foundation
import Synchronization

struct OpenAIRealtimeAudioBinding: Equatable, Sendable {
    let sessionID: SpeechSessionID
}

enum OpenAIRealtimeAudioChannelError: Error, Equatable, Sendable {
    case staleFlow
    case unsupportedWireFormat
    case invalidPCM16Payload
    case sequenceExhausted
    case downlinkRelayOverflow
    case transportClosed
    case sendFailed
}

enum OpenAIRealtimeAudioYieldPhase: Equatable, Sendable {
    case beforeYield
    case afterYield
}

@available(iOS 18, macOS 15, *)
private final class OpenAIRealtimeAudioChannelGate: Sendable {
    private struct State {
        var invalidationError: OpenAIRealtimeAudioChannelError?
    }

    let binding: OpenAIRealtimeAudioBinding

    private let state: Mutex<State>

    init(binding: OpenAIRealtimeAudioBinding) {
        self.binding = binding
        state = Mutex(State(invalidationError: nil))
    }

    func validate(_ candidate: OpenAIRealtimeAudioBinding) throws {
        let error: OpenAIRealtimeAudioChannelError? = state.withLock {
            state in
            guard candidate == binding else {
                return OpenAIRealtimeAudioChannelError.staleFlow
            }
            return state.invalidationError
        }
        if let error {
            throw error
        }
    }

    func invalidate(error: OpenAIRealtimeAudioChannelError) {
        state.withLock { state in
            guard state.invalidationError == nil else { return }
            state.invalidationError = error
        }
    }
}

@available(iOS 18, macOS 13, *)
enum OpenAIRealtimeAudioReceiveResult: Equatable, Sendable {
    case accepted(AudioFrame)
    case discardedWithoutSubscriber
    case failed(OpenAIRealtimeAudioChannelError)
}

@available(iOS 18, macOS 15, *)
struct OpenAIRealtimeAudioFrameSender: AudioFrameSender, Sendable {
    typealias SendPCM16 = @Sendable (
        _ binding: OpenAIRealtimeAudioBinding,
        _ payload: Data
    ) async throws -> Void

    let binding: OpenAIRealtimeAudioBinding
    private let sendPCM16: SendPCM16
    private let gate: OpenAIRealtimeAudioChannelGate

    init(
        binding: OpenAIRealtimeAudioBinding,
        sendPCM16: @escaping SendPCM16
    ) {
        self.init(
            binding: binding,
            gate: OpenAIRealtimeAudioChannelGate(binding: binding),
            sendPCM16: sendPCM16
        )
    }

    fileprivate init(
        binding: OpenAIRealtimeAudioBinding,
        gate: OpenAIRealtimeAudioChannelGate,
        sendPCM16: @escaping SendPCM16
    ) {
        self.binding = binding
        self.gate = gate
        self.sendPCM16 = sendPCM16
    }

    func send(_ frame: AudioFrame) async throws {
        guard binding.sessionID.accepts(frame: frame) else {
            throw OpenAIRealtimeAudioChannelError.staleFlow
        }
        guard Self.isWireFormat(frame.format) else {
            throw OpenAIRealtimeAudioChannelError.unsupportedWireFormat
        }
        try gate.validate(binding)
        do {
            try await sendPCM16(binding, frame.payload)
        } catch let error as OpenAIRealtimeAudioChannelError {
            throw error
        } catch {
            throw OpenAIRealtimeAudioChannelError.sendFailed
        }
    }

    private static func isWireFormat(
        _ format: AudioStreamFormat
    ) -> Bool {
        format.sampleRate == 24_000
            && format.channelCount == 1
            && format.sampleEncoding == .signedPCM16LittleEndian
            && format.interleaving == .interleaved
    }
}

@available(iOS 18, macOS 15, *)
final class OpenAIRealtimeAudioFrameReceiver:
    AudioFrameReceiver
{
    typealias YieldHook = @MainActor @Sendable (
        OpenAIRealtimeAudioYieldPhase
    ) -> Void

    private struct Subscription {
        let token: UUID
        let continuation:
            AsyncThrowingStream<AudioFrame, any Error>.Continuation
    }

    private struct State {
        var activeSubscription: Subscription?
        var nextSequence: UInt64
        var nextTimestamp: Duration
        var discardedWithoutSubscriber: UInt64
        var isFinished: Bool
        var terminalError: OpenAIRealtimeAudioChannelError?
    }

    private enum StreamInstallation {
        case installed(previous: Subscription?)
        case finished(error: OpenAIRealtimeAudioChannelError?)
    }

    private enum ReceivePreparation {
        case deliver(frame: AudioFrame, subscription: Subscription)
        case discarded
        case failed(OpenAIRealtimeAudioChannelError)
    }

    private struct YieldResolution {
        let result: OpenAIRealtimeAudioReceiveResult
        let continuationToFinish:
            AsyncThrowingStream<AudioFrame, any Error>.Continuation?
    }

    private enum UnacceptedYieldResult {
        case dropped
        case terminated
        case unknown
    }

    let binding: OpenAIRealtimeAudioBinding

    private let format: AudioStreamFormat
    private let state: Mutex<State>
    private let yieldHook: YieldHook?

    init(
        binding: OpenAIRealtimeAudioBinding,
        initialSequence: UInt64 = 0,
        initialTimestamp: Duration = .zero,
        yieldHook: YieldHook? = nil
    ) {
        self.binding = binding
        format = try! .monoPCM16(sampleRate: 24_000)
        self.yieldHook = yieldHook
        state = Mutex(
            State(
                activeSubscription: nil,
                nextSequence: initialSequence,
                nextTimestamp: initialTimestamp,
                discardedWithoutSubscriber: 0,
                isFinished: false,
                terminalError: nil
            )
        )
    }

    nonisolated var noSubscriberDiscardCount: UInt64 {
        state.withLock { $0.discardedWithoutSubscriber }
    }

    nonisolated func frames(
        for flowID: AudioFlowID
    ) -> AsyncThrowingStream<AudioFrame, any Error> {
        guard binding.sessionID.accepts(audioFlowID: flowID) else {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: OpenAIRealtimeAudioChannelError.staleFlow
                )
            }
        }

        let token = UUID()
        return AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(1)
        ) { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let installation: StreamInstallation = state.withLock {
                state in
                guard !state.isFinished else {
                    return .finished(error: state.terminalError)
                }
                let previous = state.activeSubscription
                state.activeSubscription = Subscription(
                    token: token,
                    continuation: continuation
                )
                return .installed(previous: previous)
            }
            switch installation {
            case let .finished(error):
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            case let .installed(previous):
                continuation.onTermination = { [weak self] _ in
                    self?.removeSubscription(token: token)
                }
                previous?.continuation.finish()
            }
        }
    }

    @MainActor
    @discardableResult
    func receivePCM16(_ payload: Data) -> OpenAIRealtimeAudioReceiveResult {
        let preparation: ReceivePreparation = state.withLock { state in
            guard !state.isFinished else {
                return .failed(state.terminalError ?? .transportClosed)
            }
            guard !payload.isEmpty,
                  payload.count.isMultiple(of: MemoryLayout<Int16>.size)
            else {
                return .failed(.invalidPCM16Payload)
            }
            guard state.nextSequence < UInt64.max else {
                return .failed(.sequenceExhausted)
            }

            let frame: AudioFrame
            do {
                let duration = try format.duration(
                    forPayloadByteCount: payload.count
                )
                frame = try AudioFrame(
                    flowID: binding.sessionID.audioFlowID,
                    sequence: state.nextSequence,
                    timestamp: state.nextTimestamp,
                    format: format,
                    payload: payload,
                    duration: duration
                )
                state.nextSequence += 1
                state.nextTimestamp += duration
            } catch {
                return .failed(.invalidPCM16Payload)
            }

            guard let subscription = state.activeSubscription else {
                state.discardedWithoutSubscriber &+= 1
                return .discarded
            }
            return .deliver(frame: frame, subscription: subscription)
        }

        switch preparation {
        case let .failed(error):
            return .failed(error)
        case .discarded:
            return .discardedWithoutSubscriber
        case let .deliver(frame, subscription):
            yieldHook?(.beforeYield)
            let preYieldResult: OpenAIRealtimeAudioReceiveResult? =
                state.withLock { state in
                    guard !state.isFinished else {
                        return .failed(
                            state.terminalError ?? .transportClosed
                        )
                    }
                    guard state.activeSubscription?.token
                        == subscription.token
                    else {
                        state.discardedWithoutSubscriber &+= 1
                        return .discardedWithoutSubscriber
                    }
                    return nil
                }
            if let preYieldResult {
                return preYieldResult
            }
            let yieldResult = subscription.continuation.yield(frame)
            yieldHook?(.afterYield)
            let resolution = resolveYield(
                yieldResult,
                frame: frame,
                subscription: subscription
            )
            resolution.continuationToFinish?.finish(
                throwing: OpenAIRealtimeAudioChannelError
                    .downlinkRelayOverflow
            )
            return resolution.result
        }
    }

    @MainActor
    func finish(error: OpenAIRealtimeAudioChannelError? = nil) {
        let subscription = state.withLock { state -> Subscription? in
            guard !state.isFinished else { return nil }
            state.isFinished = true
            state.terminalError = error
            let subscription = state.activeSubscription
            state.activeSubscription = nil
            return subscription
        }
        if let error {
            subscription?.continuation.finish(throwing: error)
        } else {
            subscription?.continuation.finish()
        }
    }

    nonisolated private func resolveYield(
        _ yieldResult: AsyncThrowingStream<
            AudioFrame,
            any Error
        >.Continuation.YieldResult,
        frame: AudioFrame,
        subscription: Subscription
    ) -> YieldResolution {
        let unaccepted: UnacceptedYieldResult
        switch yieldResult {
        case .enqueued:
            return YieldResolution(
                result: .accepted(frame),
                continuationToFinish: nil
            )
        case .dropped:
            unaccepted = .dropped
        case .terminated:
            unaccepted = .terminated
        @unknown default:
            unaccepted = .unknown
        }

        return state.withLock { state in
            switch unaccepted {
            case .dropped:
                guard !state.isFinished else {
                    return YieldResolution(
                        result: .failed(
                            state.terminalError ?? .transportClosed
                        ),
                        continuationToFinish: nil
                    )
                }
                guard state.activeSubscription?.token
                    == subscription.token
                else {
                    state.discardedWithoutSubscriber &+= 1
                    return YieldResolution(
                        result: .discardedWithoutSubscriber,
                        continuationToFinish: nil
                    )
                }
                state.activeSubscription = nil
                return YieldResolution(
                    result: .failed(.downlinkRelayOverflow),
                    continuationToFinish: subscription.continuation
                )
            case .terminated:
                if state.activeSubscription?.token == subscription.token {
                    state.activeSubscription = nil
                }
                guard !state.isFinished else {
                    return YieldResolution(
                        result: .failed(
                            state.terminalError ?? .transportClosed
                        ),
                        continuationToFinish: nil
                    )
                }
                state.discardedWithoutSubscriber &+= 1
                return YieldResolution(
                    result: .discardedWithoutSubscriber,
                    continuationToFinish: nil
                )
            case .unknown:
                if state.activeSubscription?.token == subscription.token {
                    state.activeSubscription = nil
                }
                return YieldResolution(
                    result: .failed(.transportClosed),
                    continuationToFinish: nil
                )
            }
        }
    }

    nonisolated private func removeSubscription(token: UUID) {
        state.withLock { state in
            guard state.activeSubscription?.token == token else {
                return
            }
            state.activeSubscription = nil
        }
    }
}

@available(iOS 18, macOS 15, *)
struct OpenAIRealtimeAudioChannels: Sendable {
    let binding: OpenAIRealtimeAudioBinding
    let sender: OpenAIRealtimeAudioFrameSender
    let receiver: OpenAIRealtimeAudioFrameReceiver?
    private let gate: OpenAIRealtimeAudioChannelGate

    init(
        binding: OpenAIRealtimeAudioBinding,
        sendPCM16: @escaping OpenAIRealtimeAudioFrameSender.SendPCM16,
        includeReceiver: Bool = true
    ) {
        self.binding = binding
        let gate = OpenAIRealtimeAudioChannelGate(binding: binding)
        self.gate = gate
        sender = OpenAIRealtimeAudioFrameSender(
            binding: binding,
            gate: gate,
            sendPCM16: sendPCM16
        )
        receiver = includeReceiver
            ? OpenAIRealtimeAudioFrameReceiver(binding: binding)
            : nil
    }

    @MainActor
    func invalidate(forReplacement replacement: OpenAIRealtimeAudioBinding) {
        guard replacement != binding else { return }
        gate.invalidate(error: .staleFlow)
        receiver?.finish(error: .staleFlow)
    }
}
