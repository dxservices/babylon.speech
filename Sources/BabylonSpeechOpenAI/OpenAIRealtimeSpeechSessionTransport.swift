import BabylonSpeech
import Foundation

@available(iOS 18, macOS 15, *)
@MainActor
protocol OpenAIRealtimeSpeechSessionTransport: AnyObject, Sendable {
    var onEvent: (
        @MainActor @Sendable (OpenAIRealtimeDecodedEvent) -> Void
    )? { get set }
    var onTerminal: (
        @MainActor @Sendable (SpeechProviderFailure) -> Void
    )? { get set }

    func connect(
        targetLanguage: String,
        transcriptionRequested: Bool,
        audioBinding: OpenAIRealtimeAudioBinding,
        includeDownlink: Bool
    ) async throws(SpeechProviderFailure) -> OpenAIRealtimeAudioChannels

    func closeGracefully() async -> OpenAIRealtimeCloseOutcome

    @discardableResult
    func cancelImmediately() -> OpenAIRealtimeCloseOutcome
}

@available(iOS 18, macOS 15, *)
extension OpenAIRealtimeWebSocketTransport:
    OpenAIRealtimeSpeechSessionTransport
{}
