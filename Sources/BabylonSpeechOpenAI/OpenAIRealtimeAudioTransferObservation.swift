import BabylonSpeech
import Foundation

/// A content-free fact about OpenAI Realtime audio media transferred in one
/// direction.
///
/// Audio duration is media duration derived from the fixed provider PCM format.
/// It is not wall-clock, playback, network, or billing duration.
@available(iOS 18, macOS 15, *)
public struct OpenAIRealtimeAudioTransferFact: Sendable, Equatable {
    /// The audio transfer direction.
    public let direction: OpenAIRealtimeTransferDirection

    /// The duration of the PCM audio represented by this transfer.
    public let audioDuration: Duration

    init(
        direction: OpenAIRealtimeTransferDirection,
        audioDuration: Duration
    ) {
        self.direction = direction
        self.audioDuration = audioDuration
    }
}

/// A synchronous, content-free OpenAI Realtime audio-transfer observer.
@available(iOS 18, macOS 15, *)
public typealias OpenAIRealtimeAudioTransferObserver =
    @MainActor @Sendable (
        _ sessionID: SpeechSessionID,
        _ fact: OpenAIRealtimeAudioTransferFact
    ) -> Void
