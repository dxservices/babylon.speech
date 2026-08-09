# BabylonSpeech

BabylonSpeech is a provider-neutral real-time speech-intelligence Swift package built on BabylonAudio.

The package is in its initial pre-0.1 scaffold. It does not expose a usable public API or provider adapter yet.

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

## Development

```sh
swift package resolve
swift test
swift build
python3 Scripts/check_repository.py
```

## License

BabylonSpeech is available under the MIT License. See `LICENSE`.
