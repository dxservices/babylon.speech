import BabylonAudio
import BabylonSpeech
import Foundation
import XCTest
@testable import BabylonSpeechOpenAI

@available(iOS 18, macOS 15, *)
@MainActor
final class OpenAIRealtimeWebSocketTransportTests: XCTestCase {
    func testConnectBuildsAuthorizedTranslationRequestAndWaitsForUpdate()
        async throws
    {
        let secret = "short-lived-private-secret"
        let socket = FakeRealtimeWebSocketConnection()
        let scheduler = TestRealtimeScheduler()
        var capturedRequest: URLRequest?
        let transport = OpenAIRealtimeWebSocketTransport(
            authorization: .init(clientSecret: secret),
            connectionFactory: { request in
                capturedRequest = request
                return socket
            },
            scheduler: scheduler
        )
        let completion = CompletionProbe()

        let task = Task { @MainActor in
            try await transport.connect(
                targetLanguage: "zh-Hant",
                transcriptionRequested: true
            )
            completion.complete()
        }
        await waitUntil { socket.resumeCallCount == 1 }

        XCTAssertFalse(completion.isComplete)
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(secret)"
        )
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.host, "api.openai.com")
        XCTAssertEqual(request.url?.path, "/v1/realtime/translations")
        XCTAssertEqual(
            URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )?.queryItems,
            [URLQueryItem(name: "model", value: "gpt-realtime-translate")]
        )

        socket.emitOpen()
        await waitUntil { socket.sentTexts.count == 1 }
        XCTAssertFalse(completion.isComplete)
        let update = try jsonObject(socket.sentTexts[0])
        let session = try XCTUnwrap(update["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(
            input["transcription"] as? [String: Any]
        )
        XCTAssertEqual(update["type"] as? String, "session.update")
        XCTAssertEqual(output["language"] as? String, "zh-Hant")
        XCTAssertEqual(
            transcription["model"] as? String,
            "gpt-realtime-whisper"
        )

        socket.completeNextSend()
        try await task.value

        XCTAssertTrue(completion.isComplete)
        XCTAssertEqual(socket.receiveCallCount, 1)
        XCTAssertFalse(String(describing: transport).contains(secret))
        requireSendable(transport)
    }

    func testSynchronousOpenOnResumeCannotBeatContinuationInstallation()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        socket.resumeAction = { socket.emitOpen() }
        let transport = makeTransport(socket: socket)

        let task = Task { @MainActor in
            try await transport.connect(
                targetLanguage: "fr",
                transcriptionRequested: false
            )
        }
        await waitUntil { socket.sentTexts.count == 1 }
        socket.completeNextSend()

        try await task.value
        XCTAssertEqual(socket.receiveCallCount, 1)
    }

    func testSynchronousCloseOnResumeFailsOnceWithoutHanging() async {
        let socket = FakeRealtimeWebSocketConnection()
        socket.resumeAction = {
            socket.emitClose(SensitiveTestError("private socket detail"))
        }
        let transport = makeTransport(socket: socket)

        let failure = await connectFailure(transport)

        XCTAssertEqual(failure.classification, .network)
        XCTAssertEqual(failure.type.value, "network_error")
        XCTAssertEqual(failure.code?.value, "connection_closed")
        XCTAssertFalse(
            String(describing: failure).contains("private socket detail")
        )
        XCTAssertEqual(socket.cancelCallCount, 1)
    }

    func testOpenTimeoutUsesDeterministicSchedulerAndIgnoresLateOpen()
        async
    {
        let socket = FakeRealtimeWebSocketConnection()
        let scheduler = TestRealtimeScheduler()
        let transport = makeTransport(
            socket: socket,
            scheduler: scheduler
        )
        let task = Task { @MainActor in
            await connectFailure(transport)
        }
        await waitUntil {
            scheduler.hasActiveTask(after: .seconds(12))
        }

        scheduler.advance(by: .seconds(12))
        let failure = await task.value
        socket.emitOpen()

        XCTAssertEqual(failure.classification, .network)
        XCTAssertEqual(failure.code?.value, "connection_timed_out")
        XCTAssertEqual(socket.cancelCallCount, 1)
        XCTAssertTrue(socket.sentTexts.isEmpty)
    }

    func testCloseBeforeOpenMapsToFixedNetworkFailureAndFirstSignalWins()
        async
    {
        let socket = FakeRealtimeWebSocketConnection()
        let transport = makeTransport(socket: socket)
        let task = Task { @MainActor in await connectFailure(transport) }
        await waitUntil { socket.resumeCallCount == 1 }

        socket.emitClose(SensitiveTestError("first private detail"))
        socket.emitClose(SensitiveTestError("second private detail"))
        socket.emitOpen()
        let failure = await task.value

        XCTAssertEqual(failure.code?.value, "connection_closed")
        XCTAssertFalse(String(describing: failure).contains("private"))
        XCTAssertEqual(socket.cancelCallCount, 1)
        XCTAssertTrue(socket.sentTexts.isEmpty)
    }

    func testUpdateSendFailureMapsToFixedNetworkFailure() async {
        let socket = FakeRealtimeWebSocketConnection()
        let transport = makeTransport(socket: socket)
        let task = Task { @MainActor in await connectFailure(transport) }
        await waitUntil { socket.resumeCallCount == 1 }
        socket.emitOpen()
        await waitUntil { socket.sentTexts.count == 1 }

        socket.completeNextSend(
            error: SensitiveTestError("private update failure")
        )
        let failure = await task.value

        XCTAssertEqual(failure.classification, .network)
        XCTAssertEqual(failure.code?.value, "session_update_failed")
        XCTAssertFalse(String(describing: failure).contains("private"))
        XCTAssertEqual(socket.cancelCallCount, 1)
    }

    func testSuccessfulUpdateCompletionWinsOverImmediateClose()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        let transport = makeTransport(socket: socket)
        var events: [OpenAIRealtimeDecodedEvent] = []
        transport.onEvent = { events.append($0) }
        let task = Task { @MainActor in
            try await transport.connect(
                targetLanguage: "fr",
                transcriptionRequested: true
            )
        }
        await waitUntil { socket.resumeCallCount == 1 }
        socket.emitOpen()
        await waitUntil { socket.sentTexts.count == 1 }

        socket.completeNextSend()
        socket.emitClose(SensitiveTestError("private close detail"))
        try await task.value

        guard case let .providerFailure(failure) = events.first else {
            return XCTFail("Expected provider failure")
        }
        XCTAssertEqual(failure.classification, .network)
        XCTAssertEqual(failure.code?.value, "connection_closed")
        XCTAssertFalse(String(describing: events).contains("private"))
        XCTAssertEqual(socket.cancelCallCount, 1)
    }

    func testCallerCancellationCancelsTimeoutAndSocketAndResumesOnce()
        async
    {
        let socket = FakeRealtimeWebSocketConnection()
        let scheduler = TestRealtimeScheduler()
        let transport = makeTransport(
            socket: socket,
            scheduler: scheduler
        )
        let task = Task { @MainActor in await connectFailure(transport) }
        await waitUntil {
            scheduler.hasActiveTask(after: .seconds(12))
        }

        task.cancel()
        let failure = await task.value
        scheduler.advance(by: .seconds(12))
        socket.emitOpen()

        XCTAssertEqual(failure.classification, .network)
        XCTAssertEqual(failure.code?.value, "connection_cancelled")
        XCTAssertEqual(socket.cancelCallCount, 1)
        XCTAssertFalse(scheduler.hasActiveTask(after: .seconds(12)))
        XCTAssertTrue(socket.sentTexts.isEmpty)
    }

    func testCallerCancellationWhileUpdateSendIsPendingResumesOnce()
        async
    {
        let socket = FakeRealtimeWebSocketConnection()
        let transport = makeTransport(socket: socket)
        let task = Task { @MainActor in await connectFailure(transport) }
        await waitUntil { socket.resumeCallCount == 1 }
        socket.emitOpen()
        await waitUntil { socket.sentTexts.count == 1 }

        task.cancel()
        let failure = await task.value
        socket.completeNextSend()

        XCTAssertEqual(failure.classification, .network)
        XCTAssertEqual(failure.code?.value, "connection_cancelled")
        XCTAssertEqual(socket.cancelCallCount, 1)
        XCTAssertEqual(socket.receiveCallCount, 0)
    }

    func testNewConnectCancelsPendingConnectWithoutAffectingReplacement()
        async throws
    {
        let firstSocket = FakeRealtimeWebSocketConnection()
        let secondSocket = FakeRealtimeWebSocketConnection()
        var sockets: [FakeRealtimeWebSocketConnection] = [
            firstSocket,
            secondSocket,
        ]
        let transport = OpenAIRealtimeWebSocketTransport(
            authorization: .init(clientSecret: "test-client-secret"),
            connectionFactory: { _ in sockets.removeFirst() },
            scheduler: TestRealtimeScheduler()
        )
        let firstTask = Task { @MainActor in
            await connectFailure(transport)
        }
        await waitUntil { firstSocket.resumeCallCount == 1 }

        let secondTask = Task { @MainActor in
            try await transport.connect(
                targetLanguage: "de",
                transcriptionRequested: true
            )
        }
        await waitUntil { secondSocket.resumeCallCount == 1 }
        firstTask.cancel()
        await Task.yield()

        XCTAssertEqual(secondSocket.cancelCallCount, 0)
        let firstFailure = await firstTask.value
        XCTAssertEqual(firstFailure.code?.value, "connection_cancelled")
        XCTAssertEqual(firstSocket.cancelCallCount, 1)

        secondSocket.emitOpen()
        await waitUntil { secondSocket.sentTexts.count == 1 }
        secondSocket.completeNextSend()
        try await secondTask.value
        XCTAssertEqual(secondSocket.receiveCallCount, 1)
    }

    func testReplacementWhileUpdateSendIsPendingCancelsOldConnect()
        async throws
    {
        let firstSocket = FakeRealtimeWebSocketConnection()
        let secondSocket = FakeRealtimeWebSocketConnection()
        var sockets: [FakeRealtimeWebSocketConnection] = [
            firstSocket,
            secondSocket,
        ]
        let transport = OpenAIRealtimeWebSocketTransport(
            authorization: .init(clientSecret: "test-client-secret"),
            connectionFactory: { _ in sockets.removeFirst() },
            scheduler: TestRealtimeScheduler()
        )
        let firstTask = Task { @MainActor in
            await connectFailure(transport)
        }
        await waitUntil { firstSocket.resumeCallCount == 1 }
        firstSocket.emitOpen()
        await waitUntil { firstSocket.sentTexts.count == 1 }

        let secondTask = Task { @MainActor in
            try await transport.connect(
                targetLanguage: "de",
                transcriptionRequested: true
            )
        }
        await waitUntil { secondSocket.resumeCallCount == 1 }
        let firstFailure = await firstTask.value
        firstSocket.completeNextSend()

        XCTAssertEqual(firstFailure.code?.value, "connection_cancelled")
        XCTAssertEqual(firstSocket.cancelCallCount, 1)
        XCTAssertEqual(firstSocket.receiveCallCount, 0)
        XCTAssertEqual(secondSocket.cancelCallCount, 0)

        secondSocket.emitOpen()
        await waitUntil { secondSocket.sentTexts.count == 1 }
        secondSocket.completeNextSend()
        try await secondTask.value
        XCTAssertEqual(secondSocket.receiveCallCount, 1)
    }

    func testReplacementAfterUpdateResumeBeforeValidationCancelsOldConnect()
        async throws
    {
        let firstSocket = FakeRealtimeWebSocketConnection()
        let secondSocket = FakeRealtimeWebSocketConnection()
        let gate = TestRealtimePostUpdateGate()
        var sockets: [FakeRealtimeWebSocketConnection] = [
            firstSocket,
            secondSocket,
        ]
        let transport = OpenAIRealtimeWebSocketTransport(
            authorization: .init(clientSecret: "test-client-secret"),
            connectionFactory: { _ in sockets.removeFirst() },
            scheduler: TestRealtimeScheduler(),
            postUpdateValidationHook: { await gate.waitOnFirstCall() }
        )
        let firstTask = Task { @MainActor in
            await connectFailure(transport)
        }
        await waitUntil { firstSocket.resumeCallCount == 1 }
        firstSocket.emitOpen()
        await waitUntil { firstSocket.sentTexts.count == 1 }
        firstSocket.completeNextSend()
        await waitUntil { gate.isWaiting }

        let secondTask = Task { @MainActor in
            try await transport.connect(
                targetLanguage: "de",
                transcriptionRequested: true
            )
        }
        await waitUntil { secondSocket.resumeCallCount == 1 }
        gate.open()
        let firstFailure = await firstTask.value

        XCTAssertEqual(firstFailure.code?.value, "connection_cancelled")
        XCTAssertEqual(firstSocket.cancelCallCount, 1)
        XCTAssertEqual(secondSocket.cancelCallCount, 0)

        secondSocket.emitOpen()
        await waitUntil { secondSocket.sentTexts.count == 1 }
        secondSocket.completeNextSend()
        try await secondTask.value
        XCTAssertEqual(secondSocket.receiveCallCount, 1)
    }

    func testEmptyAuthorizationFailsAsCredentialWithoutCreatingSocket()
        async
    {
        let socket = FakeRealtimeWebSocketConnection()
        var factoryCallCount = 0
        let transport = OpenAIRealtimeWebSocketTransport(
            authorization: .init(clientSecret: ""),
            connectionFactory: { _ in
                factoryCallCount += 1
                return socket
            },
            scheduler: TestRealtimeScheduler()
        )

        let failure = await connectFailure(transport)

        XCTAssertEqual(failure.classification, .credential)
        XCTAssertEqual(failure.type.value, "authentication_error")
        XCTAssertEqual(failure.code?.value, "invalid_client_secret")
        XCTAssertEqual(factoryCallCount, 0)
    }

    func testReceiveRearmsAndForwardsDecodedEvents() async throws {
        let socket = FakeRealtimeWebSocketConnection()
        let transport = makeTransport(socket: socket)
        var events: [OpenAIRealtimeDecodedEvent] = []
        transport.onEvent = { events.append($0) }
        try await finishConnect(transport, socket: socket)

        socket.emitMessage(.string(
            #"{"type":"session.output_transcript.delta","delta":"bonjour"}"#
        ))

        XCTAssertEqual(events, [.translatedTranscriptDelta("bonjour")])
        XCTAssertEqual(socket.receiveCallCount, 2)
    }

    func testProviderErrorIsForwardedWithoutClosingAndReceiveContinues()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        let transport = makeTransport(socket: socket)
        var events: [OpenAIRealtimeDecodedEvent] = []
        transport.onEvent = { events.append($0) }
        try await finishConnect(transport, socket: socket)

        socket.emitMessage(.string(
            #"{"type":"error","error":{"type":"invalid_request_error","code":"invalid_event","message":"private detail"}}"#
        ))
        socket.emitMessage(.string(
            #"{"type":"session.input_transcript.delta","delta":"source"}"#
        ))

        XCTAssertEqual(events.count, 2)
        guard case let .providerFailure(failure) = events[0] else {
            return XCTFail("Expected provider failure")
        }
        XCTAssertEqual(failure.classification, .provider)
        XCTAssertEqual(failure.type.value, "invalid_request_error")
        XCTAssertEqual(failure.code?.value, "invalid_event")
        XCTAssertEqual(events[1], .sourceTranscriptDelta("source"))
        XCTAssertEqual(socket.receiveCallCount, 3)
        XCTAssertEqual(socket.cancelCallCount, 0)
        XCTAssertFalse(String(describing: events).contains("private detail"))
    }

    func testReceiveFailureForwardsFixedNetworkFailureAndCancels()
        async throws
    {
        let context = try await makeConnectedAudio()
        let socket = context.socket
        let transport = context.transport
        var events: [OpenAIRealtimeDecodedEvent] = []
        transport.onEvent = { events.append($0) }

        socket.emitMessageFailure(
            SensitiveTestError("private receive failure")
        )

        guard case let .providerFailure(failure) = events.first else {
            return XCTFail("Expected provider failure")
        }
        XCTAssertEqual(failure.classification, .network)
        XCTAssertEqual(failure.code?.value, "connection_closed")
        XCTAssertFalse(String(describing: events).contains("private"))
        XCTAssertEqual(socket.cancelCallCount, 1)
        await assertAudioStreamFinished(
            context.channels,
            error: .transportClosed
        )
    }

    func testPingStartsOnlyAfterPostUpdateValidationCompletes()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        let scheduler = TestRealtimeScheduler()
        let gate = TestRealtimePostUpdateGate()
        let transport = OpenAIRealtimeWebSocketTransport(
            authorization: .init(clientSecret: "test-client-secret"),
            connectionFactory: { _ in socket },
            scheduler: scheduler,
            postUpdateValidationHook: { await gate.waitOnFirstCall() }
        )
        let task = Task { @MainActor in
            try await transport.connect(
                targetLanguage: "fr",
                transcriptionRequested: true
            )
        }
        await waitUntil { socket.resumeCallCount == 1 }
        socket.emitOpen()
        await waitUntil { socket.sentTexts.count == 1 }
        socket.completeNextSend()
        await waitUntil { gate.isWaiting }

        XCTAssertFalse(scheduler.hasActiveTask(after: .seconds(15)))
        gate.open()
        try await task.value

        XCTAssertTrue(scheduler.hasActiveTask(after: .seconds(15)))
    }

    func testPingHasNoOverlapAndSuccessfulPongRearmsInterval()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        socket.automaticallyCompletesPings = false
        let scheduler = TestRealtimeScheduler()
        let transport = makeTransport(
            socket: socket,
            scheduler: scheduler
        )
        try await finishConnect(transport, socket: socket)

        scheduler.advance(by: .seconds(15))
        XCTAssertEqual(socket.pingCallCount, 1)
        XCTAssertTrue(scheduler.hasActiveTask(after: .seconds(10)))
        XCTAssertFalse(scheduler.hasActiveTask(after: .seconds(15)))

        scheduler.advance(by: .seconds(15))
        XCTAssertEqual(socket.pingCallCount, 1)
        socket.completeNextPing()

        XCTAssertFalse(scheduler.hasActiveTask(after: .seconds(10)))
        XCTAssertTrue(scheduler.hasActiveTask(after: .seconds(15)))
        XCTAssertEqual(socket.cancelCallCount, 0)
    }

    func testOnePingFailureRetriesAndSuccessfulPongResetsFailureCount()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        socket.automaticallyCompletesPings = false
        let scheduler = TestRealtimeScheduler()
        let transport = makeTransport(
            socket: socket,
            scheduler: scheduler
        )
        var events: [OpenAIRealtimeDecodedEvent] = []
        transport.onEvent = { events.append($0) }
        try await finishConnect(transport, socket: socket)

        scheduler.advance(by: .seconds(15))
        socket.completeNextPing(error: SensitiveTestError("first"))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(scheduler.hasActiveTask(after: .seconds(15)))

        scheduler.advance(by: .seconds(15))
        socket.completeNextPing()
        scheduler.advance(by: .seconds(15))
        socket.completeNextPing(error: SensitiveTestError("after reset"))

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(socket.cancelCallCount, 0)
        XCTAssertTrue(scheduler.hasActiveTask(after: .seconds(15)))
    }

    func testPingTimeoutIgnoresLateCompletionAndSecondFailureTerminates()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        socket.automaticallyCompletesPings = false
        let scheduler = TestRealtimeScheduler()
        let transport = makeTransport(
            socket: socket,
            scheduler: scheduler
        )
        let binding = makeAudioBinding()
        var events: [OpenAIRealtimeDecodedEvent] = []
        transport.onEvent = { events.append($0) }
        let channels = try await finishConnect(
            transport,
            socket: socket,
            binding: binding
        )

        scheduler.advance(by: .seconds(15))
        scheduler.advance(by: .seconds(10))
        socket.completeNextPing()
        scheduler.advance(by: .seconds(15))
        socket.completeNextPing(error: SensitiveTestError("second"))

        XCTAssertEqual(events.count, 1)
        guard case let .providerFailure(failure) = events[0] else {
            return XCTFail("Expected liveness failure")
        }
        XCTAssertEqual(failure.classification, .network)
        XCTAssertEqual(failure.type.value, "network_error")
        XCTAssertEqual(failure.code?.value, "pong_unresponsive")
        XCTAssertFalse(String(describing: events).contains("second"))
        XCTAssertEqual(socket.cancelCallCount, 1)
        XCTAssertFalse(scheduler.hasActiveTask(after: .seconds(10)))
        XCTAssertFalse(scheduler.hasActiveTask(after: .seconds(15)))
        await assertAudioStreamFinished(channels, error: .transportClosed)

        socket.completeNextPing(error: SensitiveTestError("late"))
        scheduler.advance(by: .seconds(10))
        scheduler.advance(by: .seconds(15))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(socket.cancelCallCount, 1)
    }

    func testGracefulCloseAcknowledgementStopsPingsAndForwardsClosedEvent()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        socket.automaticallyCompletesPings = false
        let scheduler = TestRealtimeScheduler()
        let transport = makeTransport(
            socket: socket,
            scheduler: scheduler
        )
        var events: [OpenAIRealtimeDecodedEvent] = []
        transport.onEvent = { events.append($0) }
        try await finishConnect(transport, socket: socket)
        let receiveCountBeforeClose = socket.receiveCallCount

        let closeTask = Task { @MainActor in
            await transport.closeGracefully()
        }
        await waitUntil { socket.sentTexts.count == 2 }
        XCTAssertEqual(
            try jsonObject(socket.sentTexts[1])["type"] as? String,
            "session.close"
        )
        socket.completeNextSend()

        XCTAssertFalse(scheduler.hasActiveTask(after: .seconds(15)))
        XCTAssertTrue(scheduler.hasActiveTask(after: .seconds(10)))
        XCTAssertEqual(socket.receiveCallCount, receiveCountBeforeClose)
        socket.emitMessage(.string(#"{"type":"session.closed"}"#))

        let closeOutcome = await closeTask.value
        XCTAssertEqual(closeOutcome, .serverAcknowledged)
        XCTAssertEqual(events, [.sessionClosed])
        XCTAssertEqual(socket.cancelCallCount, 1)
        XCTAssertFalse(scheduler.hasActiveTask(after: .seconds(10)))
    }

    func testGracefulCloseSendFailureFailsAndTerminatesImmediately()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        let scheduler = TestRealtimeScheduler()
        let transport = makeTransport(
            socket: socket,
            scheduler: scheduler
        )
        let channels = try await finishConnect(
            transport,
            socket: socket,
            binding: makeAudioBinding()
        )
        let closeTask = Task { @MainActor in
            await transport.closeGracefully()
        }
        await waitUntil { socket.sentTexts.count == 2 }

        socket.completeNextSend(
            error: SensitiveTestError("private close send error")
        )

        let closeOutcome = await closeTask.value
        XCTAssertEqual(closeOutcome, .failed)
        XCTAssertEqual(socket.cancelCallCount, 1)
        XCTAssertFalse(scheduler.hasActiveTask(after: .seconds(10)))
        XCTAssertFalse(String(describing: closeOutcome).contains(
            "private"
        ))
        await assertAudioStreamFinished(channels, error: .transportClosed)
    }

    func testGracefulCloseTimeoutIsForcedAndLateSignalsAreIgnored()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        let scheduler = TestRealtimeScheduler()
        let transport = makeTransport(
            socket: socket,
            scheduler: scheduler
        )
        var events: [OpenAIRealtimeDecodedEvent] = []
        transport.onEvent = { events.append($0) }
        let channels = try await finishConnect(
            transport,
            socket: socket,
            binding: makeAudioBinding()
        )
        let closeTask = Task { @MainActor in
            await transport.closeGracefully()
        }
        await waitUntil { socket.sentTexts.count == 2 }
        socket.completeNextSend()

        scheduler.advance(by: .seconds(10))
        let closeOutcome = await closeTask.value
        XCTAssertEqual(closeOutcome, .localForcedAfterTimeout)
        XCTAssertEqual(socket.cancelCallCount, 1)

        socket.emitMessage(.string(#"{"type":"session.closed"}"#))
        socket.emitClose(SensitiveTestError("late close"))
        scheduler.advance(by: .seconds(10))
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(socket.cancelCallCount, 1)
        XCTAssertEqual(closeOutcome, .localForcedAfterTimeout)
        await assertAudioStreamFinished(channels, error: .transportClosed)
    }

    func testGracefulCloseTimesOutWhenSendCompletionNeverReturns()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        socket.automaticallyCompletesPings = false
        let scheduler = TestRealtimeScheduler()
        let transport = makeTransport(
            socket: socket,
            scheduler: scheduler
        )
        try await finishConnect(transport, socket: socket)
        let closeTask = Task { @MainActor in
            await transport.closeGracefully()
        }
        await waitUntil { socket.sentTexts.count == 2 }

        XCTAssertFalse(scheduler.hasActiveTask(after: .seconds(15)))
        XCTAssertTrue(scheduler.hasActiveTask(after: .seconds(10)))
        scheduler.advance(by: .seconds(15))
        XCTAssertEqual(socket.pingCallCount, 0)

        scheduler.advance(by: .seconds(10))
        let closeOutcome = await closeTask.value
        XCTAssertEqual(closeOutcome, .localForcedAfterTimeout)
        XCTAssertEqual(socket.cancelCallCount, 1)

        socket.completeNextSend()
        scheduler.advance(by: .seconds(10))
        XCTAssertEqual(socket.cancelCallCount, 1)
    }

    func testNormalCloseWhileGracefulSendIsPendingCompletesLocally()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        let scheduler = TestRealtimeScheduler()
        let transport = makeTransport(
            socket: socket,
            scheduler: scheduler
        )
        var events: [OpenAIRealtimeDecodedEvent] = []
        transport.onEvent = { events.append($0) }
        let channels = try await finishConnect(
            transport,
            socket: socket,
            binding: makeAudioBinding()
        )
        let closeTask = Task { @MainActor in
            await transport.closeGracefully()
        }
        await waitUntil { socket.sentTexts.count == 2 }

        socket.emitClose(nil)

        let closeOutcome = await closeTask.value
        XCTAssertEqual(closeOutcome, .localGraceful)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(socket.cancelCallCount, 1)
        await assertAudioStreamFinished(channels, error: nil)
        socket.completeNextSend(error: SensitiveTestError("late send"))
        scheduler.advance(by: .seconds(10))
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(socket.cancelCallCount, 1)
    }

    func testNormalCloseAfterGracefulSendSuccessCompletesLocally()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        let scheduler = TestRealtimeScheduler()
        let transport = makeTransport(
            socket: socket,
            scheduler: scheduler
        )
        var events: [OpenAIRealtimeDecodedEvent] = []
        transport.onEvent = { events.append($0) }
        try await finishConnect(transport, socket: socket)
        let closeTask = Task { @MainActor in
            await transport.closeGracefully()
        }
        await waitUntil { socket.sentTexts.count == 2 }
        socket.completeNextSend()

        socket.emitClose(nil)

        let closeOutcome = await closeTask.value
        XCTAssertEqual(closeOutcome, .localGraceful)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(socket.cancelCallCount, 1)
        socket.emitMessage(.string(#"{"type":"session.closed"}"#))
        scheduler.advance(by: .seconds(10))
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(socket.cancelCallCount, 1)
    }

    func testGracefulSocketFailureWinsOverLateTimeoutAndClosedEvent()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        let scheduler = TestRealtimeScheduler()
        let transport = makeTransport(
            socket: socket,
            scheduler: scheduler
        )
        var events: [OpenAIRealtimeDecodedEvent] = []
        transport.onEvent = { events.append($0) }
        let channels = try await finishConnect(
            transport,
            socket: socket,
            binding: makeAudioBinding()
        )
        let closeTask = Task { @MainActor in
            await transport.closeGracefully()
        }
        await waitUntil { socket.sentTexts.count == 2 }
        socket.completeNextSend()

        socket.emitClose(SensitiveTestError("private socket close"))

        let closeOutcome = await closeTask.value
        XCTAssertEqual(closeOutcome, .failed)
        XCTAssertEqual(events.count, 1)
        guard case let .providerFailure(failure) = events[0] else {
            return XCTFail("Expected network failure")
        }
        XCTAssertEqual(failure.classification, .network)
        XCTAssertEqual(failure.type.value, "network_error")
        XCTAssertEqual(failure.code?.value, "connection_closed")
        XCTAssertFalse(String(describing: events).contains("private"))
        XCTAssertEqual(socket.cancelCallCount, 1)
        await assertAudioStreamFinished(channels, error: .transportClosed)

        scheduler.advance(by: .seconds(10))
        socket.emitMessage(.string(#"{"type":"session.closed"}"#))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(socket.cancelCallCount, 1)
    }

    func testRepeatedGracefulCloseSendsOnceAndWaitersShareOutcome()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        let transport = makeTransport(socket: socket)
        try await finishConnect(transport, socket: socket)

        let first = Task { @MainActor in
            await transport.closeGracefully()
        }
        await waitUntil { socket.sentTexts.count == 2 }
        let second = Task { @MainActor in
            await transport.closeGracefully()
        }
        await Task.yield()
        XCTAssertEqual(socket.sentTexts.count, 2)

        socket.completeNextSend()
        socket.emitMessage(.string(#"{"type":"session.closed"}"#))

        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .serverAcknowledged)
        XCTAssertEqual(secondOutcome, .serverAcknowledged)
        XCTAssertEqual(socket.cancelCallCount, 1)
    }

    func testGracefulWaiterCancellationIsLocalAndOtherWaiterCanAcknowledge()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        let scheduler = TestRealtimeScheduler()
        let transport = makeTransport(
            socket: socket,
            scheduler: scheduler
        )
        try await finishConnect(transport, socket: socket)
        var firstOutcome: OpenAIRealtimeCloseOutcome?
        var secondOutcome: OpenAIRealtimeCloseOutcome?
        var secondStarted = false
        let first = Task { @MainActor in
            firstOutcome = await transport.closeGracefully()
        }
        await waitUntil { socket.sentTexts.count == 2 }
        let second = Task { @MainActor in
            secondStarted = true
            secondOutcome = await transport.closeGracefully()
        }
        await waitUntil { secondStarted }

        first.cancel()

        await waitUntil { firstOutcome != nil }
        XCTAssertEqual(firstOutcome, .waitCancelled)
        XCTAssertEqual(socket.cancelCallCount, 0)
        XCTAssertEqual(socket.sentTexts.count, 2)
        XCTAssertTrue(scheduler.hasActiveTask(after: .seconds(10)))
        XCTAssertFalse(scheduler.hasActiveTask(after: .seconds(15)))
        socket.completeNextSend()

        socket.emitMessage(.string(#"{"type":"session.closed"}"#))

        await waitUntil { secondOutcome != nil }
        XCTAssertEqual(secondOutcome, .serverAcknowledged)
        XCTAssertEqual(socket.cancelCallCount, 1)
        _ = first
        _ = second
    }

    func testNormalSessionClosedForwardsEventAndTerminates()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        let scheduler = TestRealtimeScheduler()
        let transport = makeTransport(
            socket: socket,
            scheduler: scheduler
        )
        var events: [OpenAIRealtimeDecodedEvent] = []
        transport.onEvent = { events.append($0) }
        let channels = try await finishConnect(
            transport,
            socket: socket,
            binding: makeAudioBinding()
        )

        socket.emitMessage(.string(#"{"type":"session.closed"}"#))

        XCTAssertEqual(events, [.sessionClosed])
        XCTAssertEqual(socket.cancelCallCount, 1)
        XCTAssertFalse(scheduler.hasActiveTask(after: .seconds(15)))
        await assertAudioStreamFinished(channels, error: nil)
    }

    func testImmediateCancelIsIdempotentAndDetachesCallbacks() async throws {
        let socket = FakeRealtimeWebSocketConnection()
        socket.automaticallyCompletesPings = false
        let scheduler = TestRealtimeScheduler()
        let transport = makeTransport(
            socket: socket,
            scheduler: scheduler
        )
        let channels = try await finishConnect(
            transport,
            socket: socket,
            binding: makeAudioBinding()
        )
        scheduler.advance(by: .seconds(15))

        transport.cancelImmediately()
        transport.cancelImmediately()

        XCTAssertEqual(socket.cancelCallCount, 1)
        XCTAssertNil(socket.onOpen)
        XCTAssertNil(socket.onMessage)
        XCTAssertNil(socket.onClose)
        XCTAssertFalse(scheduler.hasActiveTask(after: .seconds(10)))
        XCTAssertFalse(scheduler.hasActiveTask(after: .seconds(15)))
        socket.completeNextPing(error: SensitiveTestError("late ping"))
        XCTAssertEqual(socket.cancelCallCount, 1)
        await assertAudioStreamFinished(channels, error: .transportClosed)
    }

    func testReplacementCancelsOutstandingPingAndIgnoresLatePong()
        async throws
    {
        let firstSocket = FakeRealtimeWebSocketConnection()
        firstSocket.automaticallyCompletesPings = false
        let secondSocket = FakeRealtimeWebSocketConnection()
        let scheduler = TestRealtimeScheduler()
        var connectionIndex = 0
        let transport = OpenAIRealtimeWebSocketTransport(
            authorization: .init(clientSecret: "test-client-secret"),
            connectionFactory: { _ in
                defer { connectionIndex += 1 }
                return connectionIndex == 0 ? firstSocket : secondSocket
            },
            scheduler: scheduler
        )
        var events: [OpenAIRealtimeDecodedEvent] = []
        transport.onEvent = { events.append($0) }
        try await finishConnect(transport, socket: firstSocket)
        scheduler.advance(by: .seconds(15))
        XCTAssertTrue(scheduler.hasActiveTask(after: .seconds(10)))

        let replacement = Task { @MainActor in
            try await transport.connect(
                targetLanguage: "de",
                transcriptionRequested: false
            )
        }
        await waitUntil { secondSocket.resumeCallCount == 1 }

        XCTAssertEqual(firstSocket.cancelCallCount, 1)
        XCTAssertFalse(scheduler.hasActiveTask(after: .seconds(10)))
        firstSocket.completeNextPing(
            error: SensitiveTestError("late replaced ping")
        )
        XCTAssertTrue(events.isEmpty)

        secondSocket.emitOpen()
        await waitUntil { secondSocket.sentTexts.count == 1 }
        secondSocket.completeNextSend()
        try await replacement.value
        XCTAssertTrue(scheduler.hasActiveTask(after: .seconds(15)))
    }

    func testBlockedOldWaiterCancellationCannotAffectReplacementClose()
        async throws
    {
        let firstSocket = FakeRealtimeWebSocketConnection()
        let secondSocket = FakeRealtimeWebSocketConnection()
        let scheduler = TestRealtimeScheduler()
        let cancellationGate = TestRealtimeCancellationGate()
        var connectionIndex = 0
        let transport = OpenAIRealtimeWebSocketTransport(
            authorization: .init(clientSecret: "test-client-secret"),
            connectionFactory: { _ in
                defer { connectionIndex += 1 }
                return connectionIndex == 0 ? firstSocket : secondSocket
            },
            scheduler: scheduler,
            closeWaiterCancellationHook: { action in
                await cancellationGate.waitBeforeRunning(action)
            }
        )
        try await finishConnect(transport, socket: firstSocket)
        let oldWaiter = Task { @MainActor in
            await transport.closeGracefully()
        }
        await waitUntil { firstSocket.sentTexts.count == 2 }
        oldWaiter.cancel()
        await waitUntil { cancellationGate.isWaiting }

        let replacement = Task { @MainActor in
            try await transport.connect(
                targetLanguage: "de",
                transcriptionRequested: false
            )
        }
        await waitUntil { secondSocket.resumeCallCount == 1 }
        secondSocket.emitOpen()
        await waitUntil { secondSocket.sentTexts.count == 1 }
        secondSocket.completeNextSend()
        try await replacement.value
        let oldOutcome = await oldWaiter.value
        XCTAssertEqual(oldOutcome, .localImmediate)

        var newOutcome: OpenAIRealtimeCloseOutcome?
        let newWaiter = Task { @MainActor in
            newOutcome = await transport.closeGracefully()
        }
        await waitUntil { secondSocket.sentTexts.count == 2 }
        cancellationGate.open()
        await waitUntil { cancellationGate.didRunAction }

        XCTAssertNil(newOutcome)
        XCTAssertEqual(secondSocket.cancelCallCount, 0)
        XCTAssertTrue(scheduler.hasActiveTask(after: .seconds(10)))
        secondSocket.completeNextSend()
        secondSocket.emitMessage(.string(
            #"{"type":"session.closed"}"#
        ))
        await waitUntil { newOutcome != nil }
        XCTAssertEqual(newOutcome, .serverAcknowledged)
        XCTAssertEqual(secondSocket.cancelCallCount, 1)
        _ = newWaiter
    }

    func testAudioSendUsesBoundSessionAndWaitsForSocketCompletion()
        async throws
    {
        let context = try await makeConnectedAudio()
        let (socket, transport, binding) = (
            context.socket,
            context.transport,
            context.binding
        )
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let completion = CompletionProbe()
        XCTAssertEqual(context.channels.binding, binding)
        XCTAssertNotNil(context.channels.receiver)

        let task = Task { @MainActor in
            try await transport.sendPCM16(
                binding: binding,
                payload: payload
            )
            completion.complete()
        }
        await waitUntil { socket.sentTexts.count == 2 }

        XCTAssertFalse(completion.isComplete)
        let event = try jsonObject(socket.sentTexts[1])
        XCTAssertEqual(
            event["type"] as? String,
            "session.input_audio_buffer.append"
        )
        XCTAssertEqual(
            event["audio"] as? String,
            payload.base64EncodedString()
        )

        socket.completeNextSend()
        try await task.value
        XCTAssertTrue(completion.isComplete)
    }

    func testAudioSendRejectsWrongBindingEmptyPayloadAndUnestablishedState()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        let transport = makeTransport(socket: socket)
        let binding = makeAudioBinding()
        let wrongBinding = makeAudioBinding()
        let connectTask = Task { @MainActor in
            try await transport.connect(
                targetLanguage: "fr",
                transcriptionRequested: true,
                audioBinding: binding,
                includeDownlink: true
            )
        }
        await waitUntil { socket.resumeCallCount == 1 }

        let unestablishedError = await audioSendError {
            try await transport.sendPCM16(
                binding: binding,
                payload: Data([0x01, 0x02])
            )
        }
        XCTAssertEqual(unestablishedError, .transportClosed)
        connectTask.cancel()
        _ = try? await connectTask.value

        let established = try await makeConnectedAudio(binding: binding)
        let wrongBindingError = await audioSendError {
            try await established.transport.sendPCM16(
                binding: wrongBinding,
                payload: Data([0x01, 0x02])
            )
        }
        XCTAssertEqual(wrongBindingError, .staleFlow)
        let emptyPayloadError = await audioSendError {
            try await established.transport.sendPCM16(
                binding: binding,
                payload: Data()
            )
        }
        XCTAssertEqual(emptyPayloadError, .invalidPCM16Payload)
        let oddPayloadError = await audioSendError {
            try await established.transport.sendPCM16(
                binding: binding,
                payload: Data([0x01])
            )
        }
        XCTAssertEqual(oddPayloadError, .invalidPCM16Payload)
        XCTAssertEqual(established.socket.sentTexts.count, 1)
    }

    func testAudioSendAllowsOnlyOneInFlightWithoutQueueing() async throws {
        let context = try await makeConnectedAudio()
        let (socket, transport, binding) = (
            context.socket,
            context.transport,
            context.binding
        )
        let first = Task { @MainActor in
            try await transport.sendPCM16(
                binding: binding,
                payload: Data([0x01, 0x02])
            )
        }
        await waitUntil { socket.sentTexts.count == 2 }

        let overlapError = await audioSendError {
            try await transport.sendPCM16(
                binding: binding,
                payload: Data([0x03, 0x04])
            )
        }
        XCTAssertEqual(overlapError, .uplinkRelayOverflow)
        XCTAssertEqual(socket.sentTexts.count, 2)

        socket.completeNextSend()
        try await first.value
    }

    func testAudioSendCallerCancellationWinsAndLateCompletionCannotFinishNextSend()
        async throws
    {
        let context = try await makeConnectedAudio()
        let (socket, transport, binding) = (
            context.socket,
            context.transport,
            context.binding
        )
        let cancelled = Task { @MainActor in
            await audioSendError {
                try await transport.sendPCM16(
                    binding: binding,
                    payload: Data([0x01, 0x02])
                )
            }
        }
        await waitUntil { socket.sentTexts.count == 2 }

        cancelled.cancel()
        let cancelledOutcome = await cancelled.value
        XCTAssertEqual(cancelledOutcome, .sendCancelled)
        XCTAssertEqual(socket.cancelCallCount, 0)

        let nextCompletion = CompletionProbe()
        let next = Task { @MainActor in
            try await transport.sendPCM16(
                binding: binding,
                payload: Data([0x03, 0x04])
            )
            nextCompletion.complete()
        }
        await waitUntil { socket.sentTexts.count == 3 }
        socket.completeNextSend()
        await Task.yield()
        XCTAssertFalse(nextCompletion.isComplete)

        socket.completeNextSend()
        try await next.value
        XCTAssertTrue(nextCompletion.isComplete)
    }

    func testAudioSendCompletionWinsOverBlockedLateCancellation()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        let cancellationGate = TestRealtimeCancellationGate()
        let transport = OpenAIRealtimeWebSocketTransport(
            authorization: .init(clientSecret: "test-client-secret"),
            connectionFactory: { _ in socket },
            scheduler: TestRealtimeScheduler(),
            uplinkSendCancellationHook: { action in
                await cancellationGate.waitBeforeRunning(action)
            }
        )
        let binding = makeAudioBinding()
        _ = try await finishConnect(
            transport,
            socket: socket,
            binding: binding
        )
        let first = Task { @MainActor in
            try await transport.sendPCM16(
                binding: binding,
                payload: Data([0x01, 0x02])
            )
        }
        await waitUntil { socket.sentTexts.count == 2 }
        first.cancel()
        await waitUntil { cancellationGate.isWaiting }

        socket.completeNextSend()
        try await first.value

        let nextCompletion = CompletionProbe()
        let next = Task { @MainActor in
            try await transport.sendPCM16(
                binding: binding,
                payload: Data([0x03, 0x04])
            )
            nextCompletion.complete()
        }
        await waitUntil { socket.sentTexts.count == 3 }
        cancellationGate.open()
        await waitUntil { cancellationGate.didRunAction }
        XCTAssertFalse(nextCompletion.isComplete)

        socket.completeNextSend()
        try await next.value
        XCTAssertTrue(nextCompletion.isComplete)
    }

    func testAudioSendMapsSocketErrorToFixedFailureWithoutRetainingDetail()
        async throws
    {
        let context = try await makeConnectedAudio()
        let (socket, transport, binding) = (
            context.socket,
            context.transport,
            context.binding
        )
        let send = Task { @MainActor in
            await audioSendError {
                try await transport.sendPCM16(
                    binding: binding,
                    payload: Data([0x01, 0x02])
                )
            }
        }
        await waitUntil { socket.sentTexts.count == 2 }

        socket.completeNextSend(
            error: SensitiveTestError("private uplink send detail")
        )

        let outcome = await send.value
        XCTAssertEqual(outcome, .sendFailed)
        XCTAssertFalse(String(describing: outcome).contains("private"))
        XCTAssertEqual(socket.cancelCallCount, 0)
    }

    func testAudioConnectDoesNotInstallEpochAfterImmediateRemoteTerminal()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        let gate = TestRealtimePostUpdateGate()
        let transport = OpenAIRealtimeWebSocketTransport(
            authorization: .init(clientSecret: "test-client-secret"),
            connectionFactory: { _ in socket },
            scheduler: TestRealtimeScheduler(),
            postUpdateValidationHook: { await gate.waitOnFirstCall() }
        )
        let binding = makeAudioBinding()
        let connect = Task { @MainActor in
            do {
                _ = try await transport.connect(
                    targetLanguage: "fr",
                    transcriptionRequested: true,
                    audioBinding: binding,
                    includeDownlink: true
                )
                XCTFail("Expected audio connect failure")
                return false
            } catch {
                return true
            }
        }
        await waitUntil { socket.resumeCallCount == 1 }
        socket.emitOpen()
        await waitUntil { socket.sentTexts.count == 1 }
        socket.completeNextSend()
        await waitUntil { gate.isWaiting }

        socket.emitClose(SensitiveTestError("private close"))
        gate.open()

        let didFail = await connect.value
        XCTAssertTrue(didFail)
        let sendError = await audioSendError {
            try await transport.sendPCM16(
                binding: binding,
                payload: Data([0x01, 0x02])
            )
        }
        XCTAssertEqual(sendError, .transportClosed)
    }

    func testImmediateCancelAndRemoteTerminalResumePendingAudioSend()
        async throws
    {
        let first = try await makeConnectedAudio()
        let firstSocket = first.socket
        let firstTransport = first.transport
        let firstBinding = first.binding
        let cancelled = Task { @MainActor in
            await audioSendError {
                try await firstTransport.sendPCM16(
                    binding: firstBinding,
                    payload: Data([0x01, 0x02])
                )
            }
        }
        await waitUntil { firstSocket.sentTexts.count == 2 }

        firstTransport.cancelImmediately()
        let cancelledOutcome = await cancelled.value
        XCTAssertEqual(cancelledOutcome, .transportClosed)
        firstSocket.completeNextSend()
        XCTAssertEqual(firstSocket.cancelCallCount, 1)

        let second = try await makeConnectedAudio()
        let secondSocket = second.socket
        let secondTransport = second.transport
        let secondBinding = second.binding
        let terminal = Task { @MainActor in
            await audioSendError {
                try await secondTransport.sendPCM16(
                    binding: secondBinding,
                    payload: Data([0x03, 0x04])
                )
            }
        }
        await waitUntil { secondSocket.sentTexts.count == 2 }

        secondSocket.emitClose(SensitiveTestError("private terminal"))
        let terminalOutcome = await terminal.value
        XCTAssertEqual(terminalOutcome, .transportClosed)
        secondSocket.completeNextSend()
        XCTAssertEqual(secondSocket.cancelCallCount, 1)
    }

    func testGracefulCloseResumesPendingAudioAndRejectsDrainSends()
        async throws
    {
        let context = try await makeConnectedAudio()
        let (socket, transport, binding) = (
            context.socket,
            context.transport,
            context.binding
        )
        let receiver = try XCTUnwrap(context.channels.receiver)
        var iterator = receiver.frames(
            for: binding.sessionID.audioFlowID
        ).makeAsyncIterator()
        let audio = Task { @MainActor in
            await audioSendError {
                try await transport.sendPCM16(
                    binding: binding,
                    payload: Data([0x01, 0x02])
                )
            }
        }
        await waitUntil { socket.sentTexts.count == 2 }

        let close = Task { @MainActor in await transport.closeGracefully() }
        await waitUntil { socket.sentTexts.count == 3 }
        let audioOutcome = await audio.value
        XCTAssertEqual(audioOutcome, .transportClosed)
        let drainError = await audioSendError {
            try await transport.sendPCM16(
                binding: binding,
                payload: Data([0x03, 0x04])
            )
        }
        XCTAssertEqual(drainError, .transportClosed)
        XCTAssertEqual(socket.sentTexts.count, 3)

        let finalPayload = Data([0x41, 0x42])
        socket.emitMessage(audioMessage(finalPayload))
        let finalFrame = try await iterator.next()
        XCTAssertEqual(finalFrame?.payload, finalPayload)

        socket.completeNextSend()
        socket.completeNextSend()
        socket.emitMessage(.string(#"{"type":"session.closed"}"#))
        let closeOutcome = await close.value
        XCTAssertEqual(closeOutcome, .serverAcknowledged)
        let terminal = try await iterator.next()
        XCTAssertNil(terminal)
    }

    func testInvalidDownlinkTerminatesAudioPersistentlyButKeepsTextOpen()
        async throws
    {
        let context = try await makeConnectedAudio()
        let receiver = try XCTUnwrap(context.channels.receiver)
        let activeProbe = AudioStreamProbe()
        let activeTask = activeProbe.consume(receiver.frames(
            for: context.binding.sessionID.audioFlowID
        ))
        var events: [OpenAIRealtimeDecodedEvent] = []
        context.transport.onEvent = { events.append($0) }

        context.socket.emitMessage(audioMessage(Data([0x01])))
        await waitUntil { activeProbe.isComplete }
        guard activeProbe.isComplete else {
            activeTask.cancel()
            return
        }
        XCTAssertEqual(activeProbe.terminalError, .invalidPCM16Payload)

        let lateProbe = AudioStreamProbe()
        let lateTask = lateProbe.consume(receiver.frames(
            for: context.binding.sessionID.audioFlowID
        ))
        await waitUntil { lateProbe.isComplete }
        guard lateProbe.isComplete else {
            lateTask.cancel()
            return
        }
        XCTAssertEqual(lateProbe.terminalError, .invalidPCM16Payload)

        context.socket.emitMessage(.string(
            #"{"type":"session.output_transcript.delta","delta":"still open"}"#
        ))
        XCTAssertEqual(events, [.translatedTranscriptDelta("still open")])
        XCTAssertEqual(context.socket.cancelCallCount, 0)
        _ = activeTask
        _ = lateTask
    }

    func testDownlinkOverflowDrainsFrameAndPersistsTerminalError()
        async throws
    {
        let context = try await makeConnectedAudio()
        let receiver = try XCTUnwrap(context.channels.receiver)
        let stream = receiver.frames(
            for: context.binding.sessionID.audioFlowID
        )
        let acceptedPayload = Data([0x11, 0x12])
        context.socket.emitMessage(audioMessage(acceptedPayload))
        context.socket.emitMessage(audioMessage(Data([0x13, 0x14])))

        let activeProbe = AudioStreamProbe()
        let activeTask = activeProbe.consume(stream)
        await waitUntil { activeProbe.isComplete }
        guard activeProbe.isComplete else {
            activeTask.cancel()
            return
        }
        XCTAssertEqual(activeProbe.frames.map(\.payload), [acceptedPayload])
        XCTAssertEqual(activeProbe.terminalError, .downlinkRelayOverflow)

        let lateProbe = AudioStreamProbe()
        let lateTask = lateProbe.consume(receiver.frames(
            for: context.binding.sessionID.audioFlowID
        ))
        await waitUntil { lateProbe.isComplete }
        guard lateProbe.isComplete else {
            lateTask.cancel()
            return
        }
        XCTAssertEqual(lateProbe.terminalError, .downlinkRelayOverflow)
        XCTAssertEqual(context.socket.cancelCallCount, 0)
        _ = activeTask
        _ = lateTask
    }

    func testSameBindingReplacementRejectsOldEpochAndIsolatesCallbacks()
        async throws
    {
        let firstSocket = FakeRealtimeWebSocketConnection()
        let secondSocket = FakeRealtimeWebSocketConnection()
        let cancellationGate = TestRealtimeCancellationGate()
        var sockets = [firstSocket, secondSocket]
        let transport = OpenAIRealtimeWebSocketTransport(
            authorization: .init(clientSecret: "test-client-secret"),
            connectionFactory: { _ in sockets.removeFirst() },
            scheduler: TestRealtimeScheduler(),
            uplinkSendCancellationHook: { action in
                await cancellationGate.waitBeforeRunning(action)
            }
        )
        let binding = makeAudioBinding()
        let frame = try makeAudioFrame(
            binding: binding,
            payload: Data([0x01, 0x02])
        )
        let oldChannels = try await finishConnect(
            transport,
            socket: firstSocket,
            binding: binding
        )
        var oldIterator = try XCTUnwrap(oldChannels.receiver).frames(
            for: binding.sessionID.audioFlowID
        ).makeAsyncIterator()
        let oldSend = Task { @MainActor in
            await audioSendError {
                try await oldChannels.sender.send(frame)
            }
        }
        await waitUntil { firstSocket.sentTexts.count == 2 }
        oldSend.cancel()
        await waitUntil { cancellationGate.isWaiting }

        let replacement = Task { @MainActor in
            try await transport.connect(
                targetLanguage: "de",
                transcriptionRequested: false,
                audioBinding: binding,
                includeDownlink: true
            )
        }
        await waitUntil { secondSocket.resumeCallCount == 1 }
        let oldSendOutcome = await oldSend.value
        XCTAssertEqual(oldSendOutcome, .staleFlow)
        do {
            _ = try await oldIterator.next()
            XCTFail("Expected replaced receiver to finish")
        } catch let error as OpenAIRealtimeAudioChannelError {
            XCTAssertEqual(error, .staleFlow)
        }
        secondSocket.emitOpen()
        await waitUntil { secondSocket.sentTexts.count == 1 }
        secondSocket.completeNextSend()
        let newChannels = try await replacement.value
        firstSocket.emitMessage(audioMessage(Data([0x11, 0x12])))
        XCTAssertEqual(
            newChannels.receiver?.noSubscriberDiscardCount,
            0
        )
        let staleSenderError = await audioSendError {
            try await oldChannels.sender.send(frame)
        }
        XCTAssertEqual(staleSenderError, .staleFlow)

        let newSend = Task { @MainActor in
            try await newChannels.sender.send(frame)
        }
        await waitUntil { secondSocket.sentTexts.count == 2 }
        cancellationGate.open()
        await waitUntil { cancellationGate.didRunAction }
        firstSocket.completeNextSend()
        await Task.yield()
        secondSocket.completeNextSend()
        try await newSend.value
    }

    func testTranslatedAudioGoesOnlyToBoundReceiverAndNotEventCallback()
        async throws
    {
        let context = try await makeConnectedAudio()
        let (socket, transport, binding) = (
            context.socket,
            context.transport,
            context.binding
        )
        let payload = Data([0x31, 0x32])
        var events: [OpenAIRealtimeDecodedEvent] = []
        transport.onEvent = { events.append($0) }
        let receiver = try XCTUnwrap(context.channels.receiver)
        var iterator = receiver.frames(
            for: binding.sessionID.audioFlowID
        ).makeAsyncIterator()

        let messages: [(String, String, Data)] = [
            ("session.output_audio.delta", "delta", payload),
            ("response.output_audio.delta", "delta", Data([0x33, 0x34])),
            ("response.audio.delta", "audio", Data([0x35, 0x36])),
        ]
        for (type, field, expectedPayload) in messages {
            socket.emitMessage(audioMessage(
                expectedPayload,
                type: type,
                field: field
            ))
            XCTAssertTrue(events.isEmpty)
            let frame = try await iterator.next()
            XCTAssertEqual(frame?.flowID, binding.sessionID.audioFlowID)
            XCTAssertEqual(frame?.payload, expectedPayload)
        }
        XCTAssertEqual(socket.receiveCallCount, 4)

        socket.emitMessage(.string(
            #"{"type":"session.output_transcript.delta","delta":"bonjour"}"#
        ))
        XCTAssertEqual(events, [.translatedTranscriptDelta("bonjour")])

        socket.emitClose(SensitiveTestError("private terminal"))
        do {
            _ = try await iterator.next()
            XCTFail("Expected terminal receiver failure")
        } catch let error as OpenAIRealtimeAudioChannelError {
            XCTAssertEqual(error, .transportClosed)
        }
    }

    func testAudioIsDroppedBeforeValidationAndWhenDownlinkIsDisabled()
        async throws
    {
        let socket = FakeRealtimeWebSocketConnection()
        let gate = TestRealtimePostUpdateGate()
        let transport = OpenAIRealtimeWebSocketTransport(
            authorization: .init(clientSecret: "test-client-secret"),
            connectionFactory: { _ in socket },
            scheduler: TestRealtimeScheduler(),
            postUpdateValidationHook: { await gate.waitOnFirstCall() }
        )
        let binding = makeAudioBinding()
        var events: [OpenAIRealtimeDecodedEvent] = []
        transport.onEvent = { events.append($0) }
        let connect = Task { @MainActor in
            try await transport.connect(
                targetLanguage: "fr",
                transcriptionRequested: true,
                audioBinding: binding,
                includeDownlink: false
            )
        }
        await waitUntil { socket.resumeCallCount == 1 }
        socket.emitOpen()
        await waitUntil { socket.sentTexts.count == 1 }
        socket.completeNextSend()
        await waitUntil { gate.isWaiting }

        socket.emitMessage(audioMessage(Data([0x41, 0x42])))
        XCTAssertTrue(events.isEmpty)
        gate.open()
        let channels = try await connect.value
        XCTAssertNil(channels.receiver)

        socket.emitMessage(audioMessage(Data([0x43, 0x44])))
        XCTAssertTrue(events.isEmpty)
    }

    func testURLSessionConnectionSatisfiesCompileAndSendableSeam() {
        let request = URLRequest(
            url: URL(string: "wss://example.invalid/realtime")!
        )
        let connection: any OpenAIRealtimeWebSocketConnection =
            URLSessionRealtimeWebSocketConnection(request: request)

        requireSendable(connection)
        connection.cancel()
    }

    func testURLSessionConnectionCancelDetachesCallbacks() async {
        let request = URLRequest(
            url: URL(string: "wss://example.invalid/realtime")!
        )
        let connection = URLSessionRealtimeWebSocketConnection(
            request: request
        )
        var closeCallCount = 0
        connection.onOpen = {}
        connection.onMessage = { _ in }
        connection.onClose = { _ in closeCallCount += 1 }

        connection.cancel()
        connection.cancel()
        connection.urlSession(
            URLSession.shared,
            task: URLSession.shared.dataTask(with: request),
            didCompleteWithError: SensitiveTestError("late private detail")
        )
        await Task.yield()

        XCTAssertNil(connection.onOpen)
        XCTAssertNil(connection.onMessage)
        XCTAssertNil(connection.onClose)
        XCTAssertEqual(closeCallCount, 0)
    }

    func testURLSessionConnectionCloseSignalsAreFirstWins() async {
        let request = URLRequest(
            url: URL(string: "wss://example.invalid/realtime")!
        )
        let connection = URLSessionRealtimeWebSocketConnection(
            request: request
        )
        var receivedErrors: [(any Error)?] = []
        connection.onClose = { receivedErrors.append($0) }
        let callbackTask = URLSession.shared.webSocketTask(with: request)

        connection.urlSession(
            URLSession.shared,
            task: callbackTask,
            didCompleteWithError: SensitiveTestError("first private detail")
        )
        await waitUntil { receivedErrors.count == 1 }
        connection.urlSession(
            URLSession.shared,
            webSocketTask: callbackTask,
            didCloseWith: .normalClosure,
            reason: nil
        )
        await Task.yield()

        XCTAssertEqual(receivedErrors.count, 1)
        XCTAssertEqual(
            (receivedErrors[0] as? SensitiveTestError)?.detail,
            "first private detail"
        )
        connection.cancel()
    }

    func testURLSessionConnectionDidCloseWinsOverLaterCompletion() async {
        let request = URLRequest(
            url: URL(string: "wss://example.invalid/realtime")!
        )
        let connection = URLSessionRealtimeWebSocketConnection(
            request: request
        )
        var receivedErrors: [(any Error)?] = []
        connection.onClose = { receivedErrors.append($0) }
        let callbackTask = URLSession.shared.webSocketTask(with: request)

        connection.urlSession(
            URLSession.shared,
            webSocketTask: callbackTask,
            didCloseWith: .normalClosure,
            reason: nil
        )
        await waitUntil { receivedErrors.count == 1 }
        connection.urlSession(
            URLSession.shared,
            task: callbackTask,
            didCompleteWithError: SensitiveTestError("late private detail")
        )
        await Task.yield()

        XCTAssertEqual(receivedErrors.count, 1)
        XCTAssertNil(receivedErrors[0])
        connection.cancel()
    }

    private func makeTransport(
        socket: FakeRealtimeWebSocketConnection,
        scheduler: TestRealtimeScheduler = TestRealtimeScheduler()
    ) -> OpenAIRealtimeWebSocketTransport {
        OpenAIRealtimeWebSocketTransport(
            authorization: .init(clientSecret: "test-client-secret"),
            connectionFactory: { _ in socket },
            scheduler: scheduler
        )
    }

    private func finishConnect(
        _ transport: OpenAIRealtimeWebSocketTransport,
        socket: FakeRealtimeWebSocketConnection
    ) async throws {
        let task = Task { @MainActor in
            try await transport.connect(
                targetLanguage: "fr",
                transcriptionRequested: true
            )
        }
        await waitUntil { socket.resumeCallCount == 1 }
        socket.emitOpen()
        await waitUntil { socket.sentTexts.count == 1 }
        socket.completeNextSend()
        try await task.value
    }

    private func finishConnect(
        _ transport: OpenAIRealtimeWebSocketTransport,
        socket: FakeRealtimeWebSocketConnection,
        binding: OpenAIRealtimeAudioBinding
    ) async throws -> OpenAIRealtimeAudioChannels {
        let task = Task { @MainActor in
            try await transport.connect(
                targetLanguage: "fr",
                transcriptionRequested: true,
                audioBinding: binding,
                includeDownlink: true
            )
        }
        await waitUntil { socket.resumeCallCount == 1 }
        socket.emitOpen()
        await waitUntil { socket.sentTexts.count == 1 }
        socket.completeNextSend()
        return try await task.value
    }

    private func makeConnectedAudio(
        binding: OpenAIRealtimeAudioBinding? = nil
    ) async throws -> (
        socket: FakeRealtimeWebSocketConnection,
        transport: OpenAIRealtimeWebSocketTransport,
        binding: OpenAIRealtimeAudioBinding,
        channels: OpenAIRealtimeAudioChannels
    ) {
        let socket = FakeRealtimeWebSocketConnection()
        let transport = makeTransport(socket: socket)
        let binding = binding ?? makeAudioBinding()
        let channels = try await finishConnect(
            transport,
            socket: socket,
            binding: binding
        )
        return (socket, transport, binding, channels)
    }

    private func makeAudioBinding() -> OpenAIRealtimeAudioBinding {
        OpenAIRealtimeAudioBinding(
            sessionID: SpeechSessionID(audioFlowID: .init())
        )
    }

    private func audioMessage(
        _ payload: Data,
        type: String = "session.output_audio.delta",
        field: String = "delta"
    ) -> OpenAIRealtimeWebSocketMessage {
        .string(
            #"{"type":"\#(type)","\#(field)":"\#(payload.base64EncodedString())"}"#
        )
    }

    private func makeAudioFrame(
        binding: OpenAIRealtimeAudioBinding,
        payload: Data
    ) throws -> AudioFrame {
        try AudioFrame(
            flowID: binding.sessionID.audioFlowID,
            sequence: 0,
            timestamp: .zero,
            format: .monoPCM16(sampleRate: 24_000),
            payload: payload,
            duration: try AudioStreamFormat
                .monoPCM16(sampleRate: 24_000)
                .duration(forPayloadByteCount: payload.count)
        )
    }

    private func audioSendError(
        _ operation: @escaping @MainActor () async throws -> Void
    ) async -> OpenAIRealtimeAudioChannelError {
        do {
            try await operation()
            XCTFail("Expected audio send failure")
        } catch let error as OpenAIRealtimeAudioChannelError {
            return error
        } catch {
            XCTFail("Expected safe audio channel failure")
        }
        return .sendFailed
    }

    private func assertAudioStreamFinished(
        _ channels: OpenAIRealtimeAudioChannels,
        error expectedError: OpenAIRealtimeAudioChannelError?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard let receiver = channels.receiver else {
            return XCTFail(
                "Expected downlink receiver",
                file: file,
                line: line
            )
        }
        let probe = AudioStreamProbe()
        let task = probe.consume(receiver.frames(
            for: channels.binding.sessionID.audioFlowID
        ))
        await waitUntil { probe.isComplete }
        guard probe.isComplete else {
            task.cancel()
            return
        }
        XCTAssertEqual(
            probe.terminalError,
            expectedError,
            file: file,
            line: line
        )
        _ = task
    }

    private func connectFailure(
        _ transport: OpenAIRealtimeWebSocketTransport
    ) async -> SpeechProviderFailure {
        do {
            try await transport.connect(
                targetLanguage: "fr",
                transcriptionRequested: true
            )
            XCTFail("Expected connection failure")
        } catch let failure {
            return failure
        }
        return makeUnexpectedFailure()
    }

    private func makeUnexpectedFailure() -> SpeechProviderFailure {
        SpeechProviderFailure(
            classification: .provider,
            type: try! SpeechFailureIdentifier("unexpected_test_failure"),
            code: nil
        )
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any]
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

@available(iOS 18, macOS 13, *)
@MainActor
private final class FakeRealtimeWebSocketConnection:
    OpenAIRealtimeWebSocketConnection
{
    var onOpen: (@MainActor @Sendable () -> Void)?
    var onMessage: (
        @MainActor @Sendable (
            Result<OpenAIRealtimeWebSocketMessage, any Error>
        ) -> Void
    )?
    var onClose: (@MainActor @Sendable ((any Error)?) -> Void)?

    var resumeAction: (@MainActor () -> Void)?
    private(set) var resumeCallCount = 0
    private(set) var receiveCallCount = 0
    private(set) var sentTexts: [String] = []
    private(set) var pingCallCount = 0
    private(set) var cancelCallCount = 0
    var automaticallyCompletesPings = true
    private var sendCompletions: [
        @MainActor @Sendable ((any Error)?) -> Void
    ] = []
    private var pingCompletions: [
        @MainActor @Sendable ((any Error)?) -> Void
    ] = []

    func resume() {
        resumeCallCount += 1
        resumeAction?()
    }

    func receive() {
        receiveCallCount += 1
    }

    func send(
        text: String,
        completion: @escaping @MainActor @Sendable ((any Error)?) -> Void
    ) {
        sentTexts.append(text)
        sendCompletions.append(completion)
    }

    func sendPing(
        completion: @escaping @MainActor @Sendable ((any Error)?) -> Void
    ) {
        pingCallCount += 1
        if automaticallyCompletesPings {
            completion(nil)
        } else {
            pingCompletions.append(completion)
        }
    }

    func cancel() {
        cancelCallCount += 1
    }

    func emitOpen() {
        onOpen?()
    }

    func emitMessage(_ message: OpenAIRealtimeWebSocketMessage) {
        onMessage?(.success(message))
    }

    func emitMessageFailure(_ error: any Error) {
        onMessage?(.failure(error))
    }

    func emitClose(_ error: (any Error)?) {
        onClose?(error)
    }

    func completeNextSend(error: (any Error)? = nil) {
        guard !sendCompletions.isEmpty else { return }
        sendCompletions.removeFirst()(error)
    }

    func completeNextPing(error: (any Error)? = nil) {
        guard !pingCompletions.isEmpty else { return }
        pingCompletions.removeFirst()(error)
    }
}

@available(iOS 18, macOS 13, *)
@MainActor
private final class TestRealtimeScheduler: OpenAIRealtimeScheduler {
    private struct Entry {
        let delay: Duration
        let task: TestRealtimeScheduledTask
    }

    private var entries: [Entry] = []

    func schedule(
        after delay: Duration,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any OpenAIRealtimeScheduledTask {
        let task = TestRealtimeScheduledTask(action: action)
        entries.append(Entry(delay: delay, task: task))
        return task
    }

    func hasActiveTask(after delay: Duration) -> Bool {
        entries.contains { $0.delay == delay && !$0.task.isCancelled }
    }

    func advance(by delay: Duration) {
        let due = entries.filter {
            $0.delay == delay && !$0.task.isCancelled
        }
        entries.removeAll { $0.delay == delay }
        for entry in due {
            entry.task.run()
        }
    }
}

@available(iOS 18, macOS 13, *)
@MainActor
private final class TestRealtimeScheduledTask: OpenAIRealtimeScheduledTask {
    private var action: (@MainActor @Sendable () -> Void)?

    init(action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    var isCancelled: Bool { action == nil }

    func cancel() {
        action = nil
    }

    func run() {
        let action = action
        self.action = nil
        action?()
    }
}

@available(iOS 18, macOS 13, *)
@MainActor
private final class TestRealtimePostUpdateGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var callCount = 0

    var isWaiting: Bool { continuation != nil }

    func waitOnFirstCall() async {
        callCount += 1
        guard callCount == 1 else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@available(iOS 18, macOS 13, *)
@MainActor
private final class TestRealtimeCancellationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var didRunAction = false

    var isWaiting: Bool { continuation != nil }

    func waitBeforeRunning(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        action()
        didRunAction = true
    }

    func open() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@available(iOS 18, macOS 13, *)
@MainActor
private final class CompletionProbe {
    private(set) var isComplete = false

    func complete() {
        isComplete = true
    }
}

@available(iOS 18, macOS 15, *)
@MainActor
private final class AudioStreamProbe {
    private(set) var frames: [AudioFrame] = []
    private(set) var terminalError: OpenAIRealtimeAudioChannelError?
    private(set) var isComplete = false

    func consume(
        _ stream: AsyncThrowingStream<AudioFrame, any Error>
    ) -> Task<Void, Never> {
        Task { @MainActor in
            do {
                for try await frame in stream {
                    frames.append(frame)
                }
            } catch let error as OpenAIRealtimeAudioChannelError {
                terminalError = error
            } catch {
                XCTFail("Expected fixed audio channel terminal error")
            }
            isComplete = true
        }
    }
}

private struct SensitiveTestError: Error {
    let detail: String

    init(_ detail: String) {
        self.detail = detail
    }
}

private func requireSendable<T: Sendable>(_: T) {}
