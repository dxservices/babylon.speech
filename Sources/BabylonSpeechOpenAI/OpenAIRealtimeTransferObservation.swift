import BabylonSpeech

/// The direction of an OpenAI Realtime application-payload transfer.
@available(iOS 18, macOS 15, *)
public enum OpenAIRealtimeTransferDirection: Sendable, Equatable {
    case uplink
    case downlink
}

/// A content-free fact about one OpenAI Realtime application payload.
///
/// The byte count excludes transport framing and network attribution. The
/// consuming application decides how to aggregate or attribute each fact.
@available(iOS 18, macOS 15, *)
public struct OpenAIRealtimeTransferFact: Sendable, Equatable {
    /// The transfer direction.
    public let direction: OpenAIRealtimeTransferDirection

    /// The UTF-8 text or binary application-payload byte count.
    public let applicationPayloadBytes: Int64

    init(
        direction: OpenAIRealtimeTransferDirection,
        applicationPayloadBytes: Int64
    ) {
        self.direction = direction
        self.applicationPayloadBytes = applicationPayloadBytes
    }
}

/// A synchronous, content-free OpenAI Realtime transfer observer.
@available(iOS 18, macOS 15, *)
public typealias OpenAIRealtimeTransferObserver =
    @MainActor @Sendable (
        _ sessionID: SpeechSessionID,
        _ fact: OpenAIRealtimeTransferFact
    ) -> Void
