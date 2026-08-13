# BabylonSpeech

BabylonSpeech is a provider-neutral real-time speech-intelligence Swift package built on BabylonAudio.

The package is pre-0.1. Its provider-neutral session contracts are available, while the provider adapter products remain placeholders.

## Requirements

- iOS 18 or later
- Swift 6 language mode
- Swift tools 6.0 or later
- BabylonAudio from an exact release tag before publication

During initial coordinated development, the manifest uses a sibling local-path dependency on `babylon.audio`. That dependency must be replaced with an exact remote tag before release.

## Products

- `BabylonSpeech`: provider-neutral speech session, configuration, event, capability, and failure contracts
- `BabylonSpeechOpenAI`: OpenAI Realtime wire and transport adapter
- `BabylonSpeechGoogle`: Google speech-provider adapter

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

## License

BabylonSpeech is available under the MIT License. See `LICENSE`.
