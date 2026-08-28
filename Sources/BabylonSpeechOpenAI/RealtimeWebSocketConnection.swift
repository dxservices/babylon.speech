import Foundation

@available(iOS 18, macOS 13, *)
@MainActor
protocol OpenAIRealtimeWebSocketConnection: AnyObject, Sendable {
    var onOpen: (@MainActor @Sendable () -> Void)? { get set }
    var onMessage: (
        @MainActor @Sendable (
            Result<OpenAIRealtimeWebSocketMessage, any Error>
        ) -> Void
    )? { get set }
    var onClose: (@MainActor @Sendable ((any Error)?) -> Void)? {
        get set
    }

    func resume()
    func receive()
    func send(
        text: String,
        completion: @escaping @MainActor @Sendable ((any Error)?) -> Void
    )
    func sendPing(
        completion: @escaping @MainActor @Sendable ((any Error)?) -> Void
    )
    func cancel()
}

@available(iOS 18, macOS 13, *)
@MainActor
final class URLSessionRealtimeWebSocketConnection: NSObject,
    OpenAIRealtimeWebSocketConnection,
    URLSessionWebSocketDelegate
{
    var onOpen: (@MainActor @Sendable () -> Void)?
    var onMessage: (
        @MainActor @Sendable (
            Result<OpenAIRealtimeWebSocketMessage, any Error>
        ) -> Void
    )?
    var onClose: (@MainActor @Sendable ((any Error)?) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private var isFinished = false

    init(request: URLRequest) {
        super.init()
        session = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: .main
        )
        task = session.webSocketTask(with: request)
    }

    func resume() {
        guard !isFinished else { return }
        task.resume()
    }

    func receive() {
        guard !isFinished else { return }
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.isFinished else { return }
                self.onMessage?(
                    result.map { message in
                        switch message {
                        case let .string(text):
                            .string(text)
                        case let .data(data):
                            .data(data)
                        @unknown default:
                            .data(Data())
                        }
                    }
                )
            }
        }
    }

    func send(
        text: String,
        completion: @escaping @MainActor @Sendable ((any Error)?) -> Void
    ) {
        guard !isFinished else {
            completion(URLSessionConnectionError.closed)
            return
        }
        task.send(.string(text)) { error in
            Task { @MainActor in
                completion(error)
            }
        }
    }

    func sendPing(
        completion: @escaping @MainActor @Sendable ((any Error)?) -> Void
    ) {
        guard !isFinished else {
            completion(URLSessionConnectionError.closed)
            return
        }
        task.sendPing { error in
            Task { @MainActor in
                completion(error)
            }
        }
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        onOpen = nil
        onMessage = nil
        onClose = nil
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocolName: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self, !self.isFinished else { return }
            self.onOpen?()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor [weak self] in
            self?.finish(error: nil)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            self?.finish(error: error)
        }
    }

    private func finish(error: (any Error)?) {
        guard !isFinished else { return }
        isFinished = true
        session.invalidateAndCancel()
        let callback = onClose
        onOpen = nil
        onMessage = nil
        onClose = nil
        callback?(error)
    }
}

private enum URLSessionConnectionError: Error, Sendable {
    case closed
}
