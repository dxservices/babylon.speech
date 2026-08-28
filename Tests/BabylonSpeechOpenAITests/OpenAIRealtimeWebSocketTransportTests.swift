import BabylonSpeech
import Foundation
import XCTest
@testable import BabylonSpeechOpenAI

@available(iOS 18, macOS 13, *)
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
        let socket = FakeRealtimeWebSocketConnection()
        let transport = makeTransport(socket: socket)
        var events: [OpenAIRealtimeDecodedEvent] = []
        transport.onEvent = { events.append($0) }
        try await finishConnect(transport, socket: socket)

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
    }

    func testImmediateCancelIsIdempotentAndDetachesCallbacks() async throws {
        let socket = FakeRealtimeWebSocketConnection()
        let transport = makeTransport(socket: socket)
        try await finishConnect(transport, socket: socket)

        transport.cancelImmediately()
        transport.cancelImmediately()

        XCTAssertEqual(socket.cancelCallCount, 1)
        XCTAssertNil(socket.onOpen)
        XCTAssertNil(socket.onMessage)
        XCTAssertNil(socket.onClose)
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
    private var sendCompletions: [
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
        completion(nil)
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
private final class CompletionProbe {
    private(set) var isComplete = false

    func complete() {
        isComplete = true
    }
}

private struct SensitiveTestError: Error {
    let detail: String

    init(_ detail: String) {
        self.detail = detail
    }
}

private func requireSendable<T: Sendable>(_: T) {}
