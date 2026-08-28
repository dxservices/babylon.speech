import BabylonAudio
import BabylonSpeech
import Foundation
import XCTest
@testable import BabylonSpeechOpenAI

@available(iOS 18, macOS 15, *)
@MainActor
final class OpenAIRealtimeAudioChannelsTests: XCTestCase {
    func testSenderForwardsExactBindingAndPCM16Payload() async throws {
        let binding = makeBinding()
        let recorder = AudioSendRecorder()
        let sender = OpenAIRealtimeAudioFrameSender(
            binding: binding,
            sendPCM16: { binding, payload in
                await recorder.record(binding: binding, payload: payload)
            }
        )
        let payload = pcm16(milliseconds: 20, marker: 0x31)
        let frame = try makeFrame(
            flowID: binding.sessionID.audioFlowID,
            format: .monoPCM16(sampleRate: 24_000),
            payload: payload
        )

        try await sender.send(frame)

        let records = await recorder.records
        XCTAssertEqual(records, [.init(binding: binding, payload: payload)])
        requireSendable(binding)
        requireSendable(sender)
    }

    func testSenderRejectsWrongFlowAndEveryNonWireFormat() async throws {
        let binding = makeBinding()
        let recorder = AudioSendRecorder()
        let sender = OpenAIRealtimeAudioFrameSender(
            binding: binding,
            sendPCM16: { binding, payload in
                await recorder.record(binding: binding, payload: payload)
            }
        )
        let validFormat = try AudioStreamFormat.monoPCM16(
            sampleRate: 24_000
        )
        let wrongFlow = try makeFrame(
            flowID: AudioFlowID(),
            format: validFormat,
            payload: pcm16(milliseconds: 20)
        )

        await assertSend(
            wrongFlow,
            through: sender,
            failsWith: .staleFlow
        )

        let invalidFormats = [
            try AudioStreamFormat.monoPCM16(sampleRate: 16_000),
            try AudioStreamFormat(
                sampleRate: 24_000,
                channelCount: 2,
                sampleEncoding: .signedPCM16LittleEndian,
                interleaving: .interleaved
            ),
            try AudioStreamFormat(
                sampleRate: 24_000,
                channelCount: 1,
                sampleEncoding: .float32,
                interleaving: .interleaved
            ),
            try AudioStreamFormat(
                sampleRate: 24_000,
                channelCount: 1,
                sampleEncoding: .signedPCM16LittleEndian,
                interleaving: .nonInterleaved
            ),
        ]
        for format in invalidFormats {
            let byteCount = Int(format.sampleRate / 50)
                * format.bytesPerFrame
            let frame = try makeFrame(
                flowID: binding.sessionID.audioFlowID,
                format: format,
                payload: Data(count: byteCount)
            )
            await assertSend(
                frame,
                through: sender,
                failsWith: .unsupportedWireFormat
            )
        }
        let records = await recorder.records
        XCTAssertTrue(records.isEmpty)
    }

    func testSenderMapsInjectedFailureToFixedSafeError() async throws {
        let binding = makeBinding()
        let sender = OpenAIRealtimeAudioFrameSender(
            binding: binding,
            sendPCM16: { _, _ in
                throw UnexpectedTestError()
            }
        )
        let frame = try makeFrame(
            flowID: binding.sessionID.audioFlowID,
            format: .monoPCM16(sampleRate: 24_000),
            payload: pcm16(milliseconds: 20)
        )

        await assertSend(
            frame,
            through: sender,
            failsWith: .sendFailed
        )
    }

    func testExactSessionReplacementInvalidatesSameFlowOldChannels()
        async throws
    {
        let flowID = AudioFlowID()
        let oldBinding = OpenAIRealtimeAudioBinding(
            sessionID: SpeechSessionID(audioFlowID: flowID)
        )
        let replacementBinding = OpenAIRealtimeAudioBinding(
            sessionID: SpeechSessionID(audioFlowID: flowID)
        )
        let recorder = AudioSendRecorder()
        let oldChannels = OpenAIRealtimeAudioChannels(
            binding: oldBinding,
            sendPCM16: { binding, payload in
                await recorder.record(binding: binding, payload: payload)
            }
        )
        let receiver = try XCTUnwrap(oldChannels.receiver)
        var iterator = receiver.frames(for: flowID).makeAsyncIterator()
        let frame = try makeFrame(
            flowID: flowID,
            format: .monoPCM16(sampleRate: 24_000),
            payload: pcm16(milliseconds: 20)
        )

        oldChannels.invalidate(forReplacement: oldBinding)
        try await oldChannels.sender.send(frame)
        oldChannels.invalidate(forReplacement: replacementBinding)

        await assertSend(
            frame,
            through: oldChannels.sender,
            failsWith: .staleFlow
        )
        do {
            _ = try await iterator.next()
            XCTFail("Expected replaced receiver failure")
        } catch {
            XCTAssertEqual(
                error as? OpenAIRealtimeAudioChannelError,
                .staleFlow
            )
        }
        XCTAssertEqual(
            receiver.receivePCM16(pcm16(milliseconds: 20)),
            .failed(.staleFlow)
        )
        let records = await recorder.records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.binding, oldBinding)
    }

    func testReceiverBuildsMonotonicFramesFromVariablePCMChunks()
        async throws
    {
        let binding = makeBinding()
        let receiver = OpenAIRealtimeAudioFrameReceiver(binding: binding)
        var iterator = receiver.frames(
            for: binding.sessionID.audioFlowID
        ).makeAsyncIterator()
        let firstPayload = pcm16(milliseconds: 20, marker: 0x41)
        let secondPayload = pcm16(milliseconds: 40, marker: 0x42)

        let firstResult = receiver.receivePCM16(firstPayload)
        let first = try acceptedFrame(firstResult)
        let streamedFirst = try await iterator.next()
        let secondResult = receiver.receivePCM16(secondPayload)
        let second = try acceptedFrame(secondResult)
        let streamedSecond = try await iterator.next()

        XCTAssertEqual(first.sequence, 0)
        XCTAssertEqual(first.timestamp, .zero)
        XCTAssertEqual(first.duration, .milliseconds(20))
        XCTAssertEqual(first.payload, firstPayload)
        XCTAssertEqual(second.sequence, 1)
        XCTAssertEqual(second.timestamp, .milliseconds(20))
        XCTAssertEqual(second.duration, .milliseconds(40))
        XCTAssertEqual(second.payload, secondPayload)
        XCTAssertEqual(streamedFirst, first)
        XCTAssertEqual(streamedSecond, second)
        XCTAssertEqual(
            first.format,
            try .monoPCM16(sampleRate: 24_000)
        )
        receiver.finish()
    }

    func testNoSubscriberDiscardsWithoutBufferingAndAdvancesTimeline()
        async throws
    {
        let binding = makeBinding()
        let receiver = OpenAIRealtimeAudioFrameReceiver(binding: binding)

        XCTAssertEqual(
            receiver.receivePCM16(pcm16(milliseconds: 20)),
            .discardedWithoutSubscriber
        )
        XCTAssertEqual(
            receiver.receivePCM16(pcm16(milliseconds: 40)),
            .discardedWithoutSubscriber
        )
        XCTAssertEqual(receiver.noSubscriberDiscardCount, 2)

        var iterator = receiver.frames(
            for: binding.sessionID.audioFlowID
        ).makeAsyncIterator()
        let third = try acceptedFrame(
            receiver.receivePCM16(pcm16(milliseconds: 20))
        )
        let streamedThird = try await iterator.next()

        XCTAssertEqual(third.sequence, 2)
        XCTAssertEqual(third.timestamp, .milliseconds(60))
        XCTAssertEqual(streamedThird, third)
        receiver.finish()
    }

    func testSubscriptionReplacementFinishesOnlyTheOlderSubscriber()
        async throws
    {
        let binding = makeBinding()
        let receiver = OpenAIRealtimeAudioFrameReceiver(binding: binding)
        var first = receiver.frames(
            for: binding.sessionID.audioFlowID
        ).makeAsyncIterator()
        var replacement = receiver.frames(
            for: binding.sessionID.audioFlowID
        ).makeAsyncIterator()

        let replacedNext = try await first.next()
        XCTAssertNil(replacedNext)
        let delivered = try acceptedFrame(
            receiver.receivePCM16(pcm16(milliseconds: 20))
        )

        let replacementNext = try await replacement.next()
        XCTAssertEqual(replacementNext, delivered)
        receiver.finish()
        let finishedNext = try await replacement.next()
        XCTAssertNil(finishedNext)
    }

    func testPostYieldReplacementKeepsAcceptedResultAndNewSubscriber()
        async throws
    {
        let binding = makeBinding()
        let harness = YieldReplacementHarness()
        let receiver = OpenAIRealtimeAudioFrameReceiver(
            binding: binding,
            yieldHook: { phase in
                harness.replaceIfNeeded(
                    at: .afterYield,
                    observed: phase
                )
            }
        )
        harness.receiver = receiver
        harness.flowID = binding.sessionID.audioFlowID
        let oldStream = receiver.frames(
            for: binding.sessionID.audioFlowID
        )

        let first = try acceptedFrame(
            receiver.receivePCM16(
                pcm16(milliseconds: 20, marker: 0x61)
            )
        )

        var oldIterator = oldStream.makeAsyncIterator()
        let oldFirst = try await oldIterator.next()
        let oldTerminal = try await oldIterator.next()
        XCTAssertEqual(oldFirst, first)
        XCTAssertNil(oldTerminal)
        var replacement = try XCTUnwrap(
            harness.replacementStream
        ).makeAsyncIterator()
        let second = try acceptedFrame(
            receiver.receivePCM16(
                pcm16(milliseconds: 20, marker: 0x62)
            )
        )
        XCTAssertEqual(first.sequence, 0)
        XCTAssertEqual(second.sequence, 1)
        let replacementSecond = try await replacement.next()
        XCTAssertEqual(replacementSecond, second)
        receiver.finish()
    }

    func testPreYieldReplacementDiscardsWithoutClearingNewSubscriber()
        async throws
    {
        let binding = makeBinding()
        let harness = YieldReplacementHarness()
        let receiver = OpenAIRealtimeAudioFrameReceiver(
            binding: binding,
            yieldHook: { phase in
                harness.replaceIfNeeded(
                    at: .beforeYield,
                    observed: phase
                )
            }
        )
        harness.receiver = receiver
        harness.flowID = binding.sessionID.audioFlowID
        var oldIterator = receiver.frames(
            for: binding.sessionID.audioFlowID
        ).makeAsyncIterator()

        XCTAssertEqual(
            receiver.receivePCM16(pcm16(milliseconds: 20)),
            .discardedWithoutSubscriber
        )
        let oldTerminal = try await oldIterator.next()
        XCTAssertNil(oldTerminal)
        var replacement = try XCTUnwrap(
            harness.replacementStream
        ).makeAsyncIterator()
        let second = try acceptedFrame(
            receiver.receivePCM16(pcm16(milliseconds: 20))
        )
        XCTAssertEqual(second.sequence, 1)
        XCTAssertEqual(second.timestamp, .milliseconds(20))
        let replacementSecond = try await replacement.next()
        XCTAssertEqual(replacementSecond, second)
        receiver.finish()
    }

    func testIsolationSurfaceCompilesAndFramesRemainNonisolated()
        async throws
    {
        let binding = makeBinding()
        let receiver = OpenAIRealtimeAudioFrameReceiver(binding: binding)
        let receive: @MainActor @Sendable (
            Data
        ) -> OpenAIRealtimeAudioReceiveResult = { payload in
            receiver.receivePCM16(payload)
        }
        let finish: @MainActor @Sendable (
            OpenAIRealtimeAudioChannelError?
        ) -> Void = { error in
            receiver.finish(error: error)
        }
        requireSendable(receive)
        requireSendable(finish)

        let stream = await Task.detached {
            receiver.frames(for: binding.sessionID.audioFlowID)
        }.value
        finish(nil)
        var iterator = stream.makeAsyncIterator()
        let terminal = try await iterator.next()
        XCTAssertNil(terminal)
    }

    func testOneFrameMailboxOverflowTerminatesWithoutCompressingTimeline()
        async throws
    {
        let binding = makeBinding()
        let receiver = OpenAIRealtimeAudioFrameReceiver(binding: binding)
        let saturated = receiver.frames(
            for: binding.sessionID.audioFlowID
        )

        let first = try acceptedFrame(
            receiver.receivePCM16(pcm16(milliseconds: 20, marker: 0x51))
        )
        XCTAssertEqual(
            receiver.receivePCM16(
                pcm16(milliseconds: 20, marker: 0x52)
            ),
            .failed(.downlinkRelayOverflow)
        )

        var saturatedIterator = saturated.makeAsyncIterator()
        let bufferedFirst = try await saturatedIterator.next()
        XCTAssertEqual(bufferedFirst, first)
        do {
            _ = try await saturatedIterator.next()
            XCTFail("Expected mailbox overflow")
        } catch {
            XCTAssertEqual(
                error as? OpenAIRealtimeAudioChannelError,
                .downlinkRelayOverflow
            )
        }

        var replacement = receiver.frames(
            for: binding.sessionID.audioFlowID
        ).makeAsyncIterator()
        let third = try acceptedFrame(
            receiver.receivePCM16(pcm16(milliseconds: 20, marker: 0x53))
        )
        XCTAssertEqual(third.sequence, 2)
        XCTAssertEqual(third.timestamp, .milliseconds(40))
        let replacementThird = try await replacement.next()
        XCTAssertEqual(replacementThird, third)
        receiver.finish()
    }

    func testWrongFlowSubscriptionFailsWithoutInstallingSubscriber()
        async throws
    {
        let binding = makeBinding()
        let receiver = OpenAIRealtimeAudioFrameReceiver(binding: binding)
        var stale = receiver.frames(
            for: AudioFlowID()
        ).makeAsyncIterator()

        do {
            _ = try await stale.next()
            XCTFail("Expected stale flow failure")
        } catch {
            XCTAssertEqual(
                error as? OpenAIRealtimeAudioChannelError,
                .staleFlow
            )
        }
        XCTAssertEqual(
            receiver.receivePCM16(pcm16(milliseconds: 20)),
            .discardedWithoutSubscriber
        )
    }

    func testFinishIsPersistentIdempotentAndFirstWins() async throws {
        let binding = makeBinding()
        let failedReceiver = OpenAIRealtimeAudioFrameReceiver(
            binding: binding
        )
        var active = failedReceiver.frames(
            for: binding.sessionID.audioFlowID
        ).makeAsyncIterator()
        failedReceiver.finish(error: .invalidPCM16Payload)
        failedReceiver.finish()

        do {
            _ = try await active.next()
            XCTFail("Expected receiver failure")
        } catch {
            XCTAssertEqual(
                error as? OpenAIRealtimeAudioChannelError,
                .invalidPCM16Payload
            )
        }
        var lateFailure = failedReceiver.frames(
            for: binding.sessionID.audioFlowID
        ).makeAsyncIterator()
        do {
            _ = try await lateFailure.next()
            XCTFail("Expected receiver failure")
        } catch {
            XCTAssertEqual(
                error as? OpenAIRealtimeAudioChannelError,
                .invalidPCM16Payload
            )
        }
        XCTAssertEqual(
            failedReceiver.receivePCM16(pcm16(milliseconds: 20)),
            .failed(.invalidPCM16Payload)
        )

        let normalReceiver = OpenAIRealtimeAudioFrameReceiver(
            binding: binding
        )
        normalReceiver.finish()
        normalReceiver.finish(error: .transportClosed)
        var lateNormal = normalReceiver.frames(
            for: binding.sessionID.audioFlowID
        ).makeAsyncIterator()
        let lateNormalNext = try await lateNormal.next()
        XCTAssertNil(lateNormalNext)
        XCTAssertEqual(
            normalReceiver.receivePCM16(pcm16(milliseconds: 20)),
            .failed(.transportClosed)
        )
    }

    func testNormalFinishDrainsBufferedFrameBeforeTerminal() async throws {
        let binding = makeBinding()
        let receiver = OpenAIRealtimeAudioFrameReceiver(binding: binding)
        let stream = receiver.frames(for: binding.sessionID.audioFlowID)
        let buffered = try acceptedFrame(
            receiver.receivePCM16(pcm16(milliseconds: 20))
        )

        receiver.finish()

        var iterator = stream.makeAsyncIterator()
        let drained = try await iterator.next()
        let terminal = try await iterator.next()
        XCTAssertEqual(drained, buffered)
        XCTAssertNil(terminal)
    }

    func testErrorFinishDrainsBufferedFrameBeforeTerminal() async throws {
        let binding = makeBinding()
        let receiver = OpenAIRealtimeAudioFrameReceiver(binding: binding)
        let stream = receiver.frames(for: binding.sessionID.audioFlowID)
        let buffered = try acceptedFrame(
            receiver.receivePCM16(pcm16(milliseconds: 20))
        )

        receiver.finish(error: .transportClosed)

        var iterator = stream.makeAsyncIterator()
        let drained = try await iterator.next()
        XCTAssertEqual(drained, buffered)
        do {
            _ = try await iterator.next()
            XCTFail("Expected terminal receiver failure")
        } catch {
            XCTAssertEqual(
                error as? OpenAIRealtimeAudioChannelError,
                .transportClosed
            )
        }
    }

    func testInvalidPCMDoesNotAdvanceTimeline() async throws {
        let binding = makeBinding()
        let receiver = OpenAIRealtimeAudioFrameReceiver(binding: binding)
        var iterator = receiver.frames(
            for: binding.sessionID.audioFlowID
        ).makeAsyncIterator()

        XCTAssertEqual(
            receiver.receivePCM16(Data()),
            .failed(.invalidPCM16Payload)
        )
        XCTAssertEqual(
            receiver.receivePCM16(Data(count: 3)),
            .failed(.invalidPCM16Payload)
        )
        let valid = try acceptedFrame(
            receiver.receivePCM16(pcm16(milliseconds: 20))
        )

        XCTAssertEqual(valid.sequence, 0)
        XCTAssertEqual(valid.timestamp, .zero)
        let streamedValid = try await iterator.next()
        XCTAssertEqual(streamedValid, valid)
        receiver.finish()
    }

    func testSequenceExhaustionReturnsFixedSafeError() async throws {
        let binding = makeBinding()
        let receiver = OpenAIRealtimeAudioFrameReceiver(
            binding: binding,
            initialSequence: .max
        )
        var iterator = receiver.frames(
            for: binding.sessionID.audioFlowID
        ).makeAsyncIterator()

        XCTAssertEqual(
            receiver.receivePCM16(pcm16(milliseconds: 20)),
            .failed(.sequenceExhausted)
        )
        receiver.finish(error: .sequenceExhausted)
        do {
            _ = try await iterator.next()
            XCTFail("Expected receiver failure")
        } catch {
            XCTAssertEqual(
                error as? OpenAIRealtimeAudioChannelError,
                .sequenceExhausted
            )
        }
    }

    func testChannelsCanOmitDownlinkWithoutChangingBinding() {
        let binding = makeBinding()
        let channels = OpenAIRealtimeAudioChannels(
            binding: binding,
            sendPCM16: { _, _ in },
            includeReceiver: false
        )

        XCTAssertEqual(channels.binding, binding)
        XCTAssertEqual(channels.sender.binding, binding)
        XCTAssertNil(channels.receiver)
        requireSendable(channels)
    }

    private func makeBinding() -> OpenAIRealtimeAudioBinding {
        OpenAIRealtimeAudioBinding(
            sessionID: SpeechSessionID(audioFlowID: AudioFlowID())
        )
    }

    private func makeFrame(
        flowID: AudioFlowID,
        format: AudioStreamFormat,
        payload: Data
    ) throws -> AudioFrame {
        try AudioFrame(
            flowID: flowID,
            sequence: 0,
            timestamp: .zero,
            format: format,
            payload: payload,
            duration: format.duration(
                forPayloadByteCount: payload.count
            )
        )
    }

    private func pcm16(
        milliseconds: Int,
        marker: UInt8 = 0
    ) -> Data {
        var payload = Data(count: milliseconds * 48)
        payload[0] = marker
        return payload
    }

    private func acceptedFrame(
        _ result: OpenAIRealtimeAudioReceiveResult
    ) throws -> AudioFrame {
        guard case let .accepted(frame) = result else {
            throw UnexpectedTestError()
        }
        return frame
    }

    private func assertSend(
        _ frame: AudioFrame,
        through sender: OpenAIRealtimeAudioFrameSender,
        failsWith expected: OpenAIRealtimeAudioChannelError
    ) async {
        do {
            try await sender.send(frame)
            XCTFail("Expected audio send failure")
        } catch {
            XCTAssertEqual(
                error as? OpenAIRealtimeAudioChannelError,
                expected
            )
        }
    }

}

private struct AudioSendRecord: Equatable, Sendable {
    let binding: OpenAIRealtimeAudioBinding
    let payload: Data
}

private actor AudioSendRecorder {
    private(set) var records: [AudioSendRecord] = []

    func record(binding: OpenAIRealtimeAudioBinding, payload: Data) {
        records.append(.init(binding: binding, payload: payload))
    }
}

private struct UnexpectedTestError: Error {}

@available(iOS 18, macOS 15, *)
@MainActor
private final class YieldReplacementHarness {
    var receiver: OpenAIRealtimeAudioFrameReceiver?
    var flowID: AudioFlowID?
    private(set) var replacementStream:
        AsyncThrowingStream<AudioFrame, any Error>?

    private var hasReplaced = false

    func replaceIfNeeded(
        at expectedPhase: OpenAIRealtimeAudioYieldPhase,
        observed phase: OpenAIRealtimeAudioYieldPhase
    ) {
        guard phase == expectedPhase,
              !hasReplaced,
              let receiver,
              let flowID
        else {
            return
        }
        hasReplaced = true
        replacementStream = receiver.frames(for: flowID)
    }
}

private func requireSendable<T: Sendable>(_: T) {}
