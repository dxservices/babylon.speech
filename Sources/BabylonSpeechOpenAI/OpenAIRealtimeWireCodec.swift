import Foundation

enum OpenAIRealtimeWebSocketMessage: Equatable, Sendable {
    case string(String)
    case data(Data)
}

struct OpenAIRealtimeWireCodec: Sendable {
    static let model = "gpt-realtime-translate"
    static let transcriptionModel = "gpt-realtime-whisper"

    let websocketEndpoint = URL(
        string: "wss://api.openai.com/v1/realtime/translations?model=\(Self.model)"
    )

    func sessionUpdateEvent(
        targetLanguage: String,
        transcriptionRequested: Bool
    ) -> String? {
        guard !targetLanguage.isEmpty else { return nil }
        var audio: [String: Any] = [
            "input": [
                "transcription": NSNull(),
            ],
            "output": [
                "language": targetLanguage,
            ],
        ]
        if transcriptionRequested {
            audio["input"] = [
                "transcription": [
                    "model": Self.transcriptionModel,
                ],
            ]
        }
        return encode([
            "type": "session.update",
            "session": [
                "audio": audio,
            ],
        ])
    }

    func appendAudioEvent(pcm16Audio: Data) -> String? {
        guard !pcm16Audio.isEmpty else { return nil }
        return encode([
            "type": "session.input_audio_buffer.append",
            "audio": pcm16Audio.base64EncodedString(),
        ])
    }

    func sessionCloseEvent() -> String? {
        encode(["type": "session.close"])
    }

    func decode(
        _ message: OpenAIRealtimeWebSocketMessage
    ) -> OpenAIRealtimeDecodedEvent {
        switch message {
        case let .string(text):
            OpenAIRealtimeEventDecoder.decode(Data(text.utf8))
        case let .data(data):
            OpenAIRealtimeEventDecoder.decode(data)
        }
    }

    private func encode(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
