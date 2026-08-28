import BabylonSpeech

struct OpenAIRealtimeSpeechEventMapper: Sendable {
    private enum Lane {
        case source
        case translation
    }

    private enum SegmentAllocation {
        case allocated(SpeechSegmentID)
        case exhausted
    }

    private struct SegmentState: Sendable {
        private(set) var segmentID: SpeechSegmentID?
        private var accumulatedText = ""

        mutating func activate(segmentID: SpeechSegmentID) {
            precondition(self.segmentID == nil)
            self.segmentID = segmentID
        }

        mutating func append(_ delta: String) {
            precondition(segmentID != nil)
            accumulatedText.append(delta)
        }

        mutating func complete(
            authoritativeText: String?
        ) -> (segmentID: SpeechSegmentID, text: String)? {
            guard let segmentID else { return nil }
            let text = authoritativeText ?? accumulatedText
            reset()
            return (segmentID, text)
        }

        mutating func flush()
            -> (segmentID: SpeechSegmentID, text: String)?
        {
            complete(authoritativeText: nil)
        }

        mutating func reset() {
            segmentID = nil
            accumulatedText.removeAll(keepingCapacity: true)
        }
    }

    let configuration: SpeechSessionConfiguration

    private var nextSegmentRawValue: UInt64?
    private var source = SegmentState()
    private var translation = SegmentState()
    private var isTerminal = false

    init(
        configuration: SpeechSessionConfiguration,
        initialSegmentRawValue: UInt64 = 0
    ) {
        self.configuration = configuration
        nextSegmentRawValue = initialSegmentRawValue
    }

    mutating func map(
        _ event: OpenAIRealtimeDecodedEvent
    ) -> [SpeechEvent] {
        guard !isTerminal else { return [] }

        switch event {
        case let .sourceTranscriptDelta(delta):
            guard requests(.transcription), !delta.isEmpty else { return [] }
            guard case let .allocated(segmentID) = segment(for: .source)
            else {
                return terminateForSegmentExhaustion()
            }
            source.append(delta)
            return [transcription(.delta(.init(
                segmentID: segmentID,
                text: delta,
                language: nil
            )))]
        case let .sourceTranscriptCompleted(authoritativeText):
            guard requests(.transcription) else { return [] }
            return completeSource(authoritativeText: authoritativeText)
        case let .translatedTranscriptDelta(delta):
            guard requests(.translation), !delta.isEmpty else { return [] }
            guard case let .allocated(segmentID) = segment(for: .translation)
            else {
                return terminateForSegmentExhaustion()
            }
            translation.append(delta)
            return [translated(.delta(.init(
                segmentID: segmentID,
                text: delta,
                language: configuration.targetLanguage
            )))]
        case let .translatedTranscriptCompleted(authoritativeText):
            guard requests(.translation) else { return [] }
            return completeTranslation(authoritativeText: authoritativeText)
        case .sessionClosed:
            return finish(reason: .completed)
        case let .providerFailure(failure):
            return [
                .failure(
                    sessionID: configuration.sessionID,
                    failure: failure
                ),
            ]
        case .translatedAudio, .ignored:
            return []
        }
    }

    mutating func finish(reason: SpeechSessionEndReason) -> [SpeechEvent] {
        guard !isTerminal else { return [] }
        isTerminal = true

        var events = flushAccumulatedText()
        events.append(
            .sessionEnded(
                sessionID: configuration.sessionID,
                reason: reason
            )
        )
        return events
    }

    private func requests(_ feature: SpeechFeature) -> Bool {
        configuration.features.contains(feature)
    }

    private mutating func completeSource(
        authoritativeText: String?
    ) -> [SpeechEvent] {
        guard source.segmentID != nil || authoritativeText != nil else {
            return []
        }
        guard case .allocated = segment(for: .source) else {
            return terminateForSegmentExhaustion()
        }
        guard let completion = source.complete(
            authoritativeText: authoritativeText
        ) else {
            return []
        }
        return [transcription(.completed(.init(
            segmentID: completion.segmentID,
            text: completion.text,
            language: nil
        )))]
    }

    private mutating func completeTranslation(
        authoritativeText: String?
    ) -> [SpeechEvent] {
        guard translation.segmentID != nil || authoritativeText != nil else {
            return []
        }
        guard case .allocated = segment(for: .translation) else {
            return terminateForSegmentExhaustion()
        }
        guard let completion = translation.complete(
            authoritativeText: authoritativeText
        ) else {
            return []
        }
        return [translated(.completed(.init(
            segmentID: completion.segmentID,
            text: completion.text,
            language: configuration.targetLanguage
        )))]
    }

    private mutating func segment(for lane: Lane) -> SegmentAllocation {
        switch lane {
        case .source:
            if let segmentID = source.segmentID {
                return .allocated(segmentID)
            }
        case .translation:
            if let segmentID = translation.segmentID {
                return .allocated(segmentID)
            }
        }

        guard let rawValue = nextSegmentRawValue else {
            return .exhausted
        }
        let segmentID = SpeechSegmentID(rawValue: rawValue)
        nextSegmentRawValue = rawValue == .max ? nil : rawValue + 1
        switch lane {
        case .source:
            source.activate(segmentID: segmentID)
        case .translation:
            translation.activate(segmentID: segmentID)
        }
        return .allocated(segmentID)
    }

    private func transcription(_ text: SpeechTextEvent) -> SpeechEvent {
        .transcription(
            sessionID: configuration.sessionID,
            text: text
        )
    }

    private func translated(_ text: SpeechTextEvent) -> SpeechEvent {
        .translation(
            sessionID: configuration.sessionID,
            text: text
        )
    }

    private mutating func flushAccumulatedText() -> [SpeechEvent] {
        var indexedEvents: [(SpeechSegmentID, SpeechEvent)] = []
        if let completion = source.flush() {
            indexedEvents.append((
                completion.segmentID,
                transcription(.completed(.init(
                    segmentID: completion.segmentID,
                    text: completion.text,
                    language: nil
                )))
            ))
        }
        if let completion = translation.flush() {
            indexedEvents.append((
                completion.segmentID,
                translated(.completed(.init(
                    segmentID: completion.segmentID,
                    text: completion.text,
                    language: configuration.targetLanguage
                )))
            ))
        }
        return indexedEvents
            .sorted { $0.0.rawValue < $1.0.rawValue }
            .map(\.1)
    }

    private mutating func terminateForSegmentExhaustion() -> [SpeechEvent] {
        isTerminal = true
        source.reset()
        translation.reset()
        let failure = SpeechProviderFailure(
            classification: .provider,
            type: Self.segmentSequenceExhaustedIdentifier,
            code: nil
        )
        return [
            .failure(
                sessionID: configuration.sessionID,
                failure: failure
            ),
            .sessionEnded(
                sessionID: configuration.sessionID,
                reason: .failed
            ),
        ]
    }

    private static let segmentSequenceExhaustedIdentifier: SpeechFailureIdentifier = {
        do {
            return try SpeechFailureIdentifier("segment_sequence_exhausted")
        } catch {
            preconditionFailure("Fixed failure identifier is invalid")
        }
    }()
}
