import BabylonSpeech
import Foundation

enum OpenAIRealtimeDecodedEvent: Equatable, Sendable {
    case sourceTranscriptDelta(String)
    case sourceTranscriptCompleted(String?)
    case translatedTranscriptDelta(String)
    case translatedTranscriptCompleted(String?)
    case translatedAudio(Data)
    case sessionClosed
    case providerFailure(SpeechProviderFailure)
    case ignored(wireType: String)
}

enum OpenAIRealtimeEventDecoder {
    static func decode(_ data: Data) -> OpenAIRealtimeDecodedEvent {
        guard let envelope = try? JSONDecoder().decode(
            Envelope.self,
            from: data
        ) else {
            return .ignored(wireType: "unknown")
        }

        switch envelope.type {
        case "session.input_transcript.delta":
            return envelope.delta.map(OpenAIRealtimeDecodedEvent
                .sourceTranscriptDelta) ?? ignored(envelope.type)
        // These completion names are compatibility aliases retained from the
        // existing Cinema adapter. The translation server primarily streams
        // transcript deltas, so missing and empty text remain distinguishable.
        case "session.input_transcript.done",
             "session.input_transcript.completed":
            return .sourceTranscriptCompleted(envelope.transcript)
        case "session.output_transcript.delta":
            return envelope.delta.map(OpenAIRealtimeDecodedEvent
                .translatedTranscriptDelta) ?? ignored(envelope.type)
        case "session.output_transcript.done",
             "session.output_transcript.completed":
            return .translatedTranscriptCompleted(envelope.transcript)
        case "session.output_audio.delta",
             // Compatibility aliases observed by the existing Cinema adapter.
             "response.output_audio.delta",
             "response.audio.delta":
            guard let encodedAudio = envelope.delta ?? envelope.audio,
                  let audio = Data(base64Encoded: encodedAudio)
            else {
                return ignored(envelope.type)
            }
            return .translatedAudio(audio)
        case "session.closed":
            return .sessionClosed
        case "error":
            return .providerFailure(
                failure(
                    type: envelope.error?.type,
                    code: envelope.error?.code
                )
            )
        default:
            return ignored(envelope.type)
        }
    }

    private static func ignored(
        _ wireType: String
    ) -> OpenAIRealtimeDecodedEvent {
        .ignored(wireType: OpenAIRealtimeSafeIdentifier.make(wireType))
    }

    private static func failure(
        type rawType: String?,
        code rawCode: String?
    ) -> SpeechProviderFailure {
        let safeType = OpenAIRealtimeSafeIdentifier.make(
            rawType ?? "unknown"
        )
        let safeCode = rawCode.map(OpenAIRealtimeSafeIdentifier.make)
        return SpeechProviderFailure(
            classification: classification(
                type: safeType,
                code: safeCode
            ),
            type: makeFailureIdentifier(safeType),
            code: safeCode.map(makeFailureIdentifier)
        )
    }

    private static func classification(
        type: String,
        code: String?
    ) -> SpeechProviderFailureClassification {
        let normalizedType = type.lowercased()
        let normalizedCode = code?.lowercased() ?? ""

        if normalizedCode == "session_expired"
            || expressesSessionExpiry(normalizedType)
            || expressesSessionExpiry(normalizedCode)
        {
            return .sessionExpired
        }
        if credentialTypes.contains(normalizedType)
            || credentialCodes.contains(normalizedCode)
        {
            return .credential
        }
        if rateLimitTypes.contains(normalizedType)
            || rateLimitCodes.contains(normalizedCode)
        {
            return .rateLimited
        }
        if invalidSessionCodes.contains(normalizedCode) {
            return .invalidSession
        }
        return .provider
    }

    private static func expressesSessionExpiry(_ value: String) -> Bool {
        guard value.contains("session") else { return false }
        return value.contains("expired")
            || value.contains("duration_exceeded")
            || value.contains("maximum_duration")
    }

    private static func makeFailureIdentifier(
        _ value: String
    ) -> SpeechFailureIdentifier {
        do {
            return try SpeechFailureIdentifier(value)
        } catch {
            preconditionFailure("Safe identifier construction failed")
        }
    }

    private static let credentialTypes: Set<String> = [
        "authentication_error",
        "permission_error",
    ]

    private static let credentialCodes: Set<String> = [
        "authentication_error",
        "invalid_api_key",
        "invalid_client_secret",
        "permission_denied",
    ]

    private static let rateLimitTypes: Set<String> = [
        "rate_limit_error",
    ]

    private static let rateLimitCodes: Set<String> = [
        "insufficient_quota",
        "rate_limit_exceeded",
    ]

    private static let invalidSessionCodes: Set<String> = [
        "invalid_session",
        "session_not_found",
    ]

    private struct Envelope: Decodable {
        let type: String
        let delta: String?
        let audio: String?
        let transcript: String?
        let error: EventError?
    }

    private struct EventError: Decodable {
        let type: String?
        let code: String?
    }
}

private enum OpenAIRealtimeSafeIdentifier {
    static func make(_ value: String) -> String {
        let characters = value.unicodeScalars.prefix(64).map { scalar in
            isAllowed(scalar) ? Character(scalar) : "_"
        }
        return characters.isEmpty ? "unknown" : String(characters)
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 45, 46, 48...57, 65...90, 95, 97...122:
            true
        default:
            false
        }
    }
}
