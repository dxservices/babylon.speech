import BabylonSpeech
import Foundation
import XCTest
@testable import BabylonSpeechOpenAI

final class OpenAIRealtimeWireCodecTests: XCTestCase {
    private let codec = OpenAIRealtimeWireCodec()

    func testTranslationEndpointUsesRealtimeTranslationModel() throws {
        let endpoint = try XCTUnwrap(codec.websocketEndpoint)
        let components = try XCTUnwrap(
            URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        )

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.openai.com")
        XCTAssertEqual(components.path, "/v1/realtime/translations")
        XCTAssertEqual(
            components.queryItems,
            [URLQueryItem(name: "model", value: "gpt-realtime-translate")]
        )
    }

    func testTranslationOnlySessionUpdateConfiguresTargetLanguage() throws {
        let event = try XCTUnwrap(
            codec.sessionUpdateEvent(
                targetLanguage: "fr",
                transcriptionRequested: false
            )
        )
        let object = try jsonObject(event)
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let output = try XCTUnwrap(audio["output"] as? [String: Any])

        XCTAssertEqual(object["type"] as? String, "session.update")
        XCTAssertEqual(output["language"] as? String, "fr")
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        XCTAssertTrue(input["transcription"] is NSNull)
    }

    func testSessionUpdateRequestsRealtimeWhisperTranscription() throws {
        let event = try XCTUnwrap(
            codec.sessionUpdateEvent(
                targetLanguage: "de",
                transcriptionRequested: true
            )
        )
        let object = try jsonObject(event)
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(
            input["transcription"] as? [String: Any]
        )

        XCTAssertEqual(
            transcription["model"] as? String,
            "gpt-realtime-whisper"
        )
    }

    func testAppendAudioEventEncodesPCM16AsBase64() throws {
        let audio = Data([0x01, 0x02, 0x03, 0x04])
        let event = try XCTUnwrap(
            codec.appendAudioEvent(pcm16Audio: audio)
        )
        let object = try jsonObject(event)

        XCTAssertEqual(
            object["type"] as? String,
            "session.input_audio_buffer.append"
        )
        XCTAssertEqual(
            object["audio"] as? String,
            audio.base64EncodedString()
        )
    }

    func testAppendAudioEventRejectsEmptyPCM16() {
        XCTAssertNil(codec.appendAudioEvent(pcm16Audio: Data()))
    }

    func testSessionCloseEventUsesExpectedShape() throws {
        let event = try XCTUnwrap(codec.sessionCloseEvent())

        XCTAssertEqual(
            try jsonObject(event) as NSDictionary,
            ["type": "session.close"] as NSDictionary
        )
    }

    func testDecodesInputTranscriptDelta() {
        XCTAssertEqual(
            codec.decode(.string(
                #"{"type":"session.input_transcript.delta","delta":"source"}"#
            )),
            .sourceTranscriptDelta("source")
        )
    }

    func testDecodesInputTranscriptCompletionWithOptionalText() {
        XCTAssertEqual(
            codec.decode(.string(
                #"{"type":"session.input_transcript.completed"}"#
            )),
            .sourceTranscriptCompleted(nil)
        )
        XCTAssertEqual(
            codec.decode(.string(
                #"{"type":"session.input_transcript.done","transcript":"source final"}"#
            )),
            .sourceTranscriptCompleted("source final")
        )
        XCTAssertEqual(
            codec.decode(.string(
                #"{"type":"session.input_transcript.done","transcript":""}"#
            )),
            .sourceTranscriptCompleted("")
        )
    }

    func testDecodesOutputTranscriptDeltaAndCompletion() {
        XCTAssertEqual(
            codec.decode(.string(
                #"{"type":"session.output_transcript.delta","delta":"target"}"#
            )),
            .translatedTranscriptDelta("target")
        )
        XCTAssertEqual(
            codec.decode(.string(
                #"{"type":"session.output_transcript.done","transcript":"target final"}"#
            )),
            .translatedTranscriptCompleted("target final")
        )
        XCTAssertEqual(
            codec.decode(.string(
                #"{"type":"session.output_transcript.completed"}"#
            )),
            .translatedTranscriptCompleted(nil)
        )
        XCTAssertEqual(
            codec.decode(.string(
                #"{"type":"session.output_transcript.done","transcript":""}"#
            )),
            .translatedTranscriptCompleted("")
        )
    }

    func testDecodesOfficialOutputAudioDeltaOutsideSpeechEvents() {
        let audio = Data([0x10, 0x20, 0x30, 0x40])
        let event = OpenAIRealtimeWebSocketMessage.string(
            #"{"type":"session.output_audio.delta","delta":"\#(audio.base64EncodedString())"}"#
        )

        XCTAssertEqual(codec.decode(event), .translatedAudio(audio))
    }

    func testDecodesOutputAudioCompatibilityAliases() {
        let deltaAudio = Data([0x01, 0x02])
        let audioFieldAudio = Data([0x03, 0x04])

        XCTAssertEqual(
            codec.decode(.string(
                #"{"type":"response.output_audio.delta","delta":"\#(deltaAudio.base64EncodedString())"}"#
            )),
            .translatedAudio(deltaAudio)
        )
        XCTAssertEqual(
            codec.decode(.string(
                #"{"type":"response.audio.delta","audio":"\#(audioFieldAudio.base64EncodedString())"}"#
            )),
            .translatedAudio(audioFieldAudio)
        )
    }

    func testDecodesSessionClosed() {
        XCTAssertEqual(
            codec.decode(.data(Data(#"{"type":"session.closed"}"#.utf8))),
            .sessionClosed
        )
    }

    func testProviderFailureContainsOnlySanitizedIdentifiers() throws {
        let rawMessage = "sensitive transcript and credential material"
        let rawEventID = "event-containing-private-material"
        let rawParameter = "parameter-containing-private-material"
        let oversizedCode = String(repeating: "x", count: 80)
        let event = OpenAIRealtimeWebSocketMessage.string(
            #"{"type":"error","event_id":"\#(rawEventID)","error":{"type":"invalid request\ncontent","code":"\#(oversizedCode)","message":"\#(rawMessage)","param":"\#(rawParameter)"}}"#
        )
        let decoded = codec.decode(event)
        let failure = try providerFailure(from: decoded)

        XCTAssertEqual(failure.classification, .provider)
        XCTAssertEqual(failure.type.value, "invalid_request_content")
        XCTAssertEqual(failure.code?.value.count, 64)
        XCTAssertFalse(String(describing: decoded).contains(rawMessage))
        XCTAssertFalse(String(describing: failure).contains(rawMessage))
        XCTAssertFalse(String(describing: decoded).contains(rawEventID))
        XCTAssertFalse(String(describing: decoded).contains(rawParameter))
    }

    func testProviderFailureClassificationUsesTypeAndCodeNotMessage() throws {
        let messageOnly = try providerFailure(from: codec.decode(.string(
            #"{"type":"error","error":{"type":"server_error","code":"temporary_failure","message":"session expired"}}"#
        )))
        let expired = try providerFailure(from: codec.decode(.string(
            #"{"type":"error","error":{"type":"invalid_request_error","code":"session_expired","message":"opaque"}}"#
        )))
        let credential = try providerFailure(from: codec.decode(.string(
            #"{"type":"error","error":{"type":"authentication_error","code":"invalid_client_secret"}}"#
        )))
        let rateLimited = try providerFailure(from: codec.decode(.string(
            #"{"type":"error","error":{"type":"rate_limit_error","code":"rate_limit_exceeded"}}"#
        )))

        XCTAssertEqual(messageOnly.classification, .provider)
        XCTAssertEqual(expired.classification, .sessionExpired)
        XCTAssertEqual(credential.classification, .credential)
        XCTAssertEqual(rateLimited.classification, .rateLimited)
    }

    func testMissingProviderFailureIdentifiersUseSafeFallbacks() throws {
        let failure = try providerFailure(from: codec.decode(.string(
            #"{"type":"error","error":{}}"#
        )))

        XCTAssertEqual(failure.type.value, "unknown")
        XCTAssertNil(failure.code)
    }

    func testUnknownEventRetainsOnlySafeBoundedWireType() {
        let unsafeType = "unknown event\\n" + String(repeating: "x", count: 80)
        let event = OpenAIRealtimeWebSocketMessage.string(
            #"{"type":"\#(unsafeType)"}"#
        )

        guard case let .ignored(wireType) = codec.decode(event) else {
            return XCTFail("Expected an ignored event")
        }
        XCTAssertEqual(wireType.count, 64)
        XCTAssertTrue(wireType.hasPrefix("unknown_event_"))
        XCTAssertFalse(wireType.contains("\n"))
    }

    func testMalformedPayloadIsIgnoredWithoutRetainingPayload() {
        let payload = "not JSON and possibly sensitive content"
        let decoded = codec.decode(.string(payload))

        XCTAssertEqual(decoded, .ignored(wireType: "unknown"))
        XCTAssertFalse(String(describing: decoded).contains(payload))
    }

    func testInvalidOutputAudioIsIgnoredWithoutRetainingPayload() {
        let decoded = codec.decode(.string(
            #"{"type":"session.output_audio.delta","delta":"not base64"}"#
        ))

        XCTAssertEqual(
            decoded,
            .ignored(wireType: "session.output_audio.delta")
        )
    }

    func testWireTypesAreSendable() {
        requireSendable(codec)
        requireSendable(OpenAIRealtimeWebSocketMessage.string("event"))
        requireSendable(OpenAIRealtimeDecodedEvent.sessionClosed)
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any]
        )
    }

    private func providerFailure(
        from event: OpenAIRealtimeDecodedEvent
    ) throws -> SpeechProviderFailure {
        guard case let .providerFailure(failure) = event else {
            throw UnexpectedDecodedEvent()
        }
        return failure
    }
}

private struct UnexpectedDecodedEvent: Error {}

private func requireSendable<T: Sendable>(_: T) {}
