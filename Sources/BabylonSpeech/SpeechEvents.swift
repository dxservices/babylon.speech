public struct SpeechSegmentID: Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct SpeechTextDelta: Equatable, Sendable {
    public let segmentID: SpeechSegmentID
    public let text: String
    public let language: SpeechLanguageTag?

    public init(segmentID: SpeechSegmentID, text: String, language: SpeechLanguageTag?) {
        self.segmentID = segmentID
        self.text = text
        self.language = language
    }
}

public struct SpeechTextCompletion: Equatable, Sendable {
    public let segmentID: SpeechSegmentID
    public let text: String
    public let language: SpeechLanguageTag?

    public init(segmentID: SpeechSegmentID, text: String, language: SpeechLanguageTag?) {
        self.segmentID = segmentID
        self.text = text
        self.language = language
    }
}

public enum SpeechTextEvent: Equatable, Sendable {
    /// An append-only fragment for a segment. It does not replace earlier fragments.
    case delta(SpeechTextDelta)
    /// The authoritative complete text for a segment.
    case completed(SpeechTextCompletion)

    public var segmentID: SpeechSegmentID {
        switch self {
        case let .delta(value):
            value.segmentID
        case let .completed(value):
            value.segmentID
        }
    }

    public var text: String {
        switch self {
        case let .delta(value):
            value.text
        case let .completed(value):
            value.text
        }
    }

    public var language: SpeechLanguageTag? {
        switch self {
        case let .delta(value):
            value.language
        case let .completed(value):
            value.language
        }
    }

    public var isCompleted: Bool {
        if case .completed = self {
            return true
        }
        return false
    }
}

public enum SpeechSessionEndReason: Equatable, Sendable {
    case consumerRequested
    case completed
    case replaced
    case failed
}

public enum SpeechEvent: Equatable, Sendable {
    case sessionStarted(sessionID: SpeechSessionID)
    case transcription(sessionID: SpeechSessionID, text: SpeechTextEvent)
    case translation(sessionID: SpeechSessionID, text: SpeechTextEvent)
    case failure(sessionID: SpeechSessionID, failure: SpeechProviderFailure)
    case sessionEnded(sessionID: SpeechSessionID, reason: SpeechSessionEndReason)

    public var sessionID: SpeechSessionID {
        switch self {
        case let .sessionStarted(sessionID),
             let .transcription(sessionID, _),
             let .translation(sessionID, _),
             let .failure(sessionID, _),
             let .sessionEnded(sessionID, _):
            sessionID
        }
    }
}
