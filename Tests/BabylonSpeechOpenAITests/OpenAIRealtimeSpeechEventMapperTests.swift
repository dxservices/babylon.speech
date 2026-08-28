import BabylonAudio
import BabylonSpeech
import Foundation
import XCTest
@testable import BabylonSpeechOpenAI

final class OpenAIRealtimeSpeechEventMapperTests: XCTestCase {
    func testInterleavedDeltasUseLazyGloballyUniqueSegmentIDs() throws {
        let configuration = try makeConfiguration(
            features: [.transcription, .translation],
            targetLanguage: "fr"
        )
        var mapper = OpenAIRealtimeSpeechEventMapper(
            configuration: configuration
        )

        XCTAssertTrue(mapper.map(.sourceTranscriptDelta("")).isEmpty)
        XCTAssertEqual(
            mapper.map(.translatedTranscriptDelta("cible")),
            [translationDelta("cible", id: 0, configuration: configuration)]
        )
        XCTAssertEqual(
            mapper.map(.sourceTranscriptDelta("source ")),
            [transcriptionDelta("source ", id: 1, configuration: configuration)]
        )
        XCTAssertEqual(
            mapper.map(.translatedTranscriptDelta(" encore")),
            [translationDelta(" encore", id: 0, configuration: configuration)]
        )
        XCTAssertEqual(
            mapper.map(.sourceTranscriptDelta("text")),
            [transcriptionDelta("text", id: 1, configuration: configuration)]
        )
    }

    func testSourceAndTranslationCompletionMatrixIsSymmetric() throws {
        for lane in MapperTestLane.allCases {
            try assertCompletionMatrix(for: lane)
        }
    }

    func testSessionClosedFlushesInSegmentOrderThenEndsOnce() throws {
        let configuration = try makeConfiguration(
            features: [.transcription, .translation],
            targetLanguage: "es"
        )
        var mapper = OpenAIRealtimeSpeechEventMapper(
            configuration: configuration
        )
        _ = mapper.map(.translatedTranscriptDelta("destino"))
        _ = mapper.map(.sourceTranscriptDelta("source"))

        XCTAssertEqual(
            mapper.map(.sessionClosed),
            [
                translationCompletion(
                    "destino",
                    id: 0,
                    configuration: configuration
                ),
                transcriptionCompletion(
                    "source",
                    id: 1,
                    configuration: configuration
                ),
                .sessionEnded(
                    sessionID: configuration.sessionID,
                    reason: .completed
                ),
            ]
        )
        XCTAssertTrue(mapper.map(.sessionClosed).isEmpty)
        XCTAssertTrue(mapper.map(.sourceTranscriptDelta("late")).isEmpty)
    }

    func testZeroActiveCloseEndsOnceAndIgnoresLateEvents() throws {
        let configuration = try makeConfiguration(features: [.transcription])
        var mapper = OpenAIRealtimeSpeechEventMapper(
            configuration: configuration
        )

        XCTAssertEqual(
            mapper.map(.sessionClosed),
            [
                .sessionEnded(
                    sessionID: configuration.sessionID,
                    reason: .completed
                ),
            ]
        )
        XCTAssertTrue(mapper.map(.sessionClosed).isEmpty)
        XCTAssertTrue(mapper.map(.sourceTranscriptDelta("late")).isEmpty)
    }

    func testDecoderCompletionAliasesMapAndDoNotFlushTwiceOnClose()
        throws
    {
        let configuration = try makeConfiguration(
            features: [.transcription, .translation],
            targetLanguage: "fr"
        )
        let codec = OpenAIRealtimeWireCodec()
        var mapper = OpenAIRealtimeSpeechEventMapper(
            configuration: configuration
        )
        let messages = [
            #"{"type":"session.input_transcript.done","transcript":"s0"}"#,
            #"{"type":"session.input_transcript.completed","transcript":"s1"}"#,
            #"{"type":"session.output_transcript.done","transcript":"t0"}"#,
            #"{"type":"session.output_transcript.completed","transcript":"t1"}"#,
        ]
        let expected = [
            transcriptionCompletion("s0", id: 0, configuration: configuration),
            transcriptionCompletion("s1", id: 1, configuration: configuration),
            translationCompletion("t0", id: 2, configuration: configuration),
            translationCompletion("t1", id: 3, configuration: configuration),
        ]

        for (message, event) in zip(messages, expected) {
            XCTAssertEqual(
                mapper.map(codec.decode(.string(message))),
                [event]
            )
        }
        XCTAssertEqual(
            mapper.map(codec.decode(.string(#"{"type":"session.closed"}"#))),
            [
                .sessionEnded(
                    sessionID: configuration.sessionID,
                    reason: .completed
                ),
            ]
        )
        XCTAssertTrue(mapper.map(.sessionClosed).isEmpty)
    }

    func testFinishFlushesOnceWithCallerReason() throws {
        let configuration = try makeConfiguration(
            features: [.transcription, .translation],
            targetLanguage: "ja"
        )
        var mapper = OpenAIRealtimeSpeechEventMapper(
            configuration: configuration
        )
        _ = mapper.map(.sourceTranscriptDelta("source"))

        XCTAssertEqual(
            mapper.finish(reason: .replaced),
            [
                transcriptionCompletion(
                    "source",
                    id: 0,
                    configuration: configuration
                ),
                .sessionEnded(
                    sessionID: configuration.sessionID,
                    reason: .replaced
                ),
            ]
        )
        XCTAssertTrue(mapper.finish(reason: .consumerRequested).isEmpty)
        XCTAssertTrue(mapper.map(.translatedTranscriptDelta("late")).isEmpty)
    }

    func testFeatureGatesPreventUnrequestedTextFromAllocating() throws {
        let configuration = try makeConfiguration(
            features: [.translation],
            targetLanguage: "it"
        )
        var mapper = OpenAIRealtimeSpeechEventMapper(
            configuration: configuration
        )

        XCTAssertTrue(mapper.map(.sourceTranscriptDelta("private")).isEmpty)
        XCTAssertTrue(
            mapper.map(.sourceTranscriptCompleted("private")).isEmpty
        )
        XCTAssertEqual(
            mapper.map(.translatedTranscriptDelta("target")),
            [translationDelta("target", id: 0, configuration: configuration)]
        )
        XCTAssertEqual(
            mapper.map(.sessionClosed),
            [
                translationCompletion(
                    "target",
                    id: 0,
                    configuration: configuration
                ),
                .sessionEnded(
                    sessionID: configuration.sessionID,
                    reason: .completed
                ),
            ]
        )
    }

    func testActiveTextSurvivesFailureIgnoredAndAudioEvents()
        throws
    {
        let configuration = try makeConfiguration(
            features: [.transcription, .translation],
            targetLanguage: "fr"
        )
        var mapper = OpenAIRealtimeSpeechEventMapper(
            configuration: configuration
        )
        let failure = SpeechProviderFailure(
            classification: .rateLimited,
            type: try SpeechFailureIdentifier("rate_limit_error"),
            code: try SpeechFailureIdentifier("rate_limit_exceeded")
        )
        _ = mapper.map(.sourceTranscriptDelta("so"))
        _ = mapper.map(.translatedTranscriptDelta("ta"))

        XCTAssertEqual(
            mapper.map(.providerFailure(failure)),
            [.failure(sessionID: configuration.sessionID, failure: failure)]
        )
        XCTAssertTrue(
            mapper.map(.translatedAudio(Data([0x01, 0x02]))).isEmpty
        )
        XCTAssertTrue(mapper.map(.ignored(wireType: "safe_type")).isEmpty)
        XCTAssertEqual(
            mapper.map(.sourceTranscriptDelta("urce")),
            [transcriptionDelta("urce", id: 0, configuration: configuration)]
        )
        XCTAssertEqual(
            mapper.map(.translatedTranscriptDelta("rget")),
            [translationDelta("rget", id: 1, configuration: configuration)]
        )
        XCTAssertEqual(
            mapper.map(.sourceTranscriptCompleted(nil)),
            [transcriptionCompletion("source", id: 0, configuration: configuration)]
        )
        XCTAssertEqual(
            mapper.map(.translatedTranscriptCompleted(nil)),
            [translationCompletion("target", id: 1, configuration: configuration)]
        )
    }

    func testSegmentIDExhaustionFailsSafelyAndTerminates() throws {
        let configuration = try makeConfiguration(
            features: [.transcription, .translation],
            targetLanguage: "fr"
        )
        var mapper = OpenAIRealtimeSpeechEventMapper(
            configuration: configuration,
            initialSegmentRawValue: .max
        )
        _ = mapper.map(.sourceTranscriptDelta("last"))
        _ = mapper.map(.sourceTranscriptCompleted(nil))
        let failure = SpeechProviderFailure(
            classification: .provider,
            type: try SpeechFailureIdentifier("segment_sequence_exhausted"),
            code: nil
        )

        XCTAssertEqual(
            mapper.map(.translatedTranscriptDelta("overflow")),
            [
                .failure(
                    sessionID: configuration.sessionID,
                    failure: failure
                ),
                .sessionEnded(
                    sessionID: configuration.sessionID,
                    reason: .failed
                ),
            ]
        )
        XCTAssertTrue(mapper.map(.sessionClosed).isEmpty)
    }

    func testMapperIsSendable() throws {
        let configuration = try makeConfiguration(features: [.transcription])
        requireSendable(
            OpenAIRealtimeSpeechEventMapper(configuration: configuration)
        )
    }

    private func assertCompletionMatrix(
        for lane: MapperTestLane
    ) throws {
        let configuration = try makeConfiguration(
            features: [.transcription, .translation],
            targetLanguage: "de"
        )
        for isActive in [false, true] {
            for input in MapperCompletionInput.allCases {
                var mapper = OpenAIRealtimeSpeechEventMapper(
                    configuration: configuration
                )
                if isActive {
                    XCTAssertEqual(
                        mapper.map(lane.delta("draft")),
                        [lane.expectedDelta(
                            "draft",
                            id: 0,
                            configuration: configuration
                        )]
                    )
                }

                let expectedCompletion = input.expectedText(
                    whenActive: isActive
                ).map {
                    [lane.expectedCompletion(
                        $0,
                        id: 0,
                        configuration: configuration
                    )]
                } ?? []
                XCTAssertEqual(
                    mapper.map(lane.completion(input.authoritativeText)),
                    expectedCompletion
                )

                let nextID: UInt64 = isActive || input.allocatesWhenInactive
                    ? 1
                    : 0
                XCTAssertEqual(
                    mapper.map(lane.delta("next")),
                    [lane.expectedDelta(
                        "next",
                        id: nextID,
                        configuration: configuration
                    )]
                )
            }
        }
    }

    private func makeConfiguration(
        features: Set<SpeechFeature>,
        targetLanguage: String? = nil
    ) throws -> SpeechSessionConfiguration {
        try SpeechSessionConfiguration(
            sessionID: SpeechSessionID(audioFlowID: AudioFlowID()),
            features: features,
            sourceLanguage: .automatic,
            targetLanguage: try targetLanguage.map(SpeechLanguageTag.init)
        )
    }

    private func transcriptionDelta(
        _ text: String,
        id: UInt64,
        configuration: SpeechSessionConfiguration
    ) -> SpeechEvent {
        .transcription(
            sessionID: configuration.sessionID,
            text: .delta(.init(
                segmentID: .init(rawValue: id),
                text: text,
                language: nil
            ))
        )
    }

    private func transcriptionCompletion(
        _ text: String,
        id: UInt64,
        configuration: SpeechSessionConfiguration
    ) -> SpeechEvent {
        .transcription(
            sessionID: configuration.sessionID,
            text: .completed(.init(
                segmentID: .init(rawValue: id),
                text: text,
                language: nil
            ))
        )
    }

    private func translationDelta(
        _ text: String,
        id: UInt64,
        configuration: SpeechSessionConfiguration
    ) -> SpeechEvent {
        .translation(
            sessionID: configuration.sessionID,
            text: .delta(.init(
                segmentID: .init(rawValue: id),
                text: text,
                language: configuration.targetLanguage
            ))
        )
    }

    private func translationCompletion(
        _ text: String,
        id: UInt64,
        configuration: SpeechSessionConfiguration
    ) -> SpeechEvent {
        .translation(
            sessionID: configuration.sessionID,
            text: .completed(.init(
                segmentID: .init(rawValue: id),
                text: text,
                language: configuration.targetLanguage
            ))
        )
    }

}

private enum MapperCompletionInput: CaseIterable {
    case nonempty
    case missing
    case explicitEmpty

    var authoritativeText: String? {
        switch self {
        case .nonempty:
            "authoritative"
        case .missing:
            nil
        case .explicitEmpty:
            ""
        }
    }

    var allocatesWhenInactive: Bool {
        authoritativeText != nil
    }

    func expectedText(whenActive: Bool) -> String? {
        switch self {
        case .nonempty:
            "authoritative"
        case .missing:
            whenActive ? "draft" : nil
        case .explicitEmpty:
            ""
        }
    }
}

private enum MapperTestLane: CaseIterable {
    case source
    case translation

    func delta(_ text: String) -> OpenAIRealtimeDecodedEvent {
        switch self {
        case .source:
            .sourceTranscriptDelta(text)
        case .translation:
            .translatedTranscriptDelta(text)
        }
    }

    func completion(_ text: String?) -> OpenAIRealtimeDecodedEvent {
        switch self {
        case .source:
            .sourceTranscriptCompleted(text)
        case .translation:
            .translatedTranscriptCompleted(text)
        }
    }

    func expectedDelta(
        _ text: String,
        id: UInt64,
        configuration: SpeechSessionConfiguration
    ) -> SpeechEvent {
        switch self {
        case .source:
            .transcription(
                sessionID: configuration.sessionID,
                text: .delta(.init(
                    segmentID: .init(rawValue: id),
                    text: text,
                    language: nil
                ))
            )
        case .translation:
            .translation(
                sessionID: configuration.sessionID,
                text: .delta(.init(
                    segmentID: .init(rawValue: id),
                    text: text,
                    language: configuration.targetLanguage
                ))
            )
        }
    }

    func expectedCompletion(
        _ text: String,
        id: UInt64,
        configuration: SpeechSessionConfiguration
    ) -> SpeechEvent {
        switch self {
        case .source:
            .transcription(
                sessionID: configuration.sessionID,
                text: .completed(.init(
                    segmentID: .init(rawValue: id),
                    text: text,
                    language: nil
                ))
            )
        case .translation:
            .translation(
                sessionID: configuration.sessionID,
                text: .completed(.init(
                    segmentID: .init(rawValue: id),
                    text: text,
                    language: configuration.targetLanguage
                ))
            )
        }
    }
}

private func requireSendable<T: Sendable>(_: T) {}
