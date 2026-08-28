# BabylonSpeech

BabylonSpeech is a provider-neutral real-time speech-intelligence Swift package built on BabylonAudio.

The provider-neutral contracts and the OpenAI Realtime translation adapter are implemented. The Google product remains a reserved target for later work.

## Requirements

- iOS 18 or later
- Swift 6 language mode
- Swift tools 6.0 or later
- BabylonAudio from `https://github.com/dxservices/babylon.audio.git`, pinned exactly to `0.1.0`

## Products

- `BabylonSpeech`: provider-neutral speech session, configuration, event, capability, and failure contracts
- `BabylonSpeechOpenAI`: OpenAI Realtime translation provider, wire codec, transport, and session-bound audio channels
- `BabylonSpeechGoogle`: reserved Google adapter target

Provider-specific dependencies must remain inside their corresponding product. The neutral product must not import provider SDKs or expose WebSocket, gRPC, base64, or provider event names.

## Ownership boundary

BabylonSpeech consumes BabylonAudio frames and produces provider-neutral speech-intelligence events. It may support translation, transcription, speaker identification, and speaker separation.

It does not own:

- Credential acquisition or persistence
- Reconnection, rotation, fallback, retry-budget, provider-selection, or billing policy
- `AVAudioSession`, `AVAudioEngine`, routes, capture, playback, or audio buffering
- Application UI, product state, or content persistence
- Raw audio, transcript, credential, provider-payload, or full-error logging

Provider adapters accept explicitly injected authorization material and report structured failures. The consuming application decides recovery.

## OpenAI Realtime usage

The application must inject an app-owned, short-lived Realtime client secret. Never pass a long-lived server API key into the package or ship one in a client application. BabylonSpeech does not acquire, refresh, persist, or log credentials. The application owns secret delivery, session recovery, and provider recreation.

`OpenAIRealtimeSpeechProvider` uses automatic source-language detection and requires translation with a target language. Transcription is optional. Uplink and translated-audio downlink both use 24 kHz, mono, interleaved, signed PCM16 little-endian frames.

```swift
import BabylonAudio
import BabylonSpeech
import BabylonSpeechOpenAI

let authorization = OpenAIRealtimeAuthorization(
    clientSecret: shortLivedClientSecret
)
let provider = OpenAIRealtimeSpeechProvider(authorization: authorization)
let configuration = try SpeechSessionConfiguration(
    sessionID: SpeechSessionID(audioFlowID: audioFlowID),
    features: [.translation, .transcription],
    sourceLanguage: .automatic,
    targetLanguage: SpeechLanguageTag("fr")
)

let channels = try await provider.startSession(configuration)
let eventTask = Task {
    for await event in channels.events {
        // Consume provider-neutral text, failure, and lifecycle events.
    }
}

try await channels.uplink.send(capturedPCM16Frame)

// Stop from the owning application lifecycle when local work is complete.
await provider.stopSession(configuration.sessionID)
await eventTask.value
```

Omit `.transcription` for translation-only sessions. Always stop a session when the application is done with it; after a terminal failure, the application decides whether and when to create a new provider and session.

## Session channels

Starting a provider session returns `SpeechSessionChannels`. The handle binds its event, uplink, and optional downlink channels to one `SpeechSessionID` and its `AudioFlowID`.

```swift
let channels = try await provider.startSession(configuration)

// This is the application injection point for captured or external PCM.
try await channels.uplink.send(audioFrame)

for await event in channels.events {
    // SpeechEvent carries text and lifecycle facts, never PCM.
}

if let downlink = channels.downlink {
    for try await translatedFrame in downlink.frames(
        for: channels.sessionID.audioFlowID
    ) {
        // Route the frame into the BabylonAudio downlink data plane.
    }
}
```

`downlink` is `nil` for providers that produce no audio, including transcription-only or local-model implementations. Consumers holding only `any SpeechProvider` receive all channels from `startSession`; provider-specific downcasts are not part of the contract.

## Development

```sh
swift package resolve
swift test
swift build
python3 Scripts/check_repository.py
```

The repository check requires a non-shallow Git checkout and scans every commit reachable from local refs. CI must fetch full history.

All repository tests use unit or fake transports. They do not inspect a credential, require a key, or make live OpenAI requests.

## License

BabylonSpeech is available under the MIT License. See `LICENSE`.
