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
let provider = OpenAIRealtimeSpeechProvider(
    authorization: authorization,
    transferObserver: { sessionID, fact in
        // Aggregate content-free application-payload bytes in app state.
        // Network-interface attribution also remains an app responsibility.
        recordTransfer(sessionID, fact.direction, fact.applicationPayloadBytes)
    },
    audioTransferObserver: { sessionID, fact in
        // Aggregate content-free PCM media duration in app state.
        recordAudioTransfer(
            sessionID,
            fact.direction,
            fact.audioDuration
        )
    }
)
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

// The original overload remains a graceful, outcome-discarding convenience.
await provider.stopSession(configuration.sessionID)
await eventTask.value
```

Omit `.transcription` for translation-only sessions. Always stop a session when the application is done with it; after a terminal failure, the application decides whether and when to create a new provider and session.

Applications that must distinguish bounded graceful completion from immediate
transport cancellation can select a mode and inspect the content-free result:

```swift
let outcome = await provider.stopSession(
    configuration.sessionID,
    mode: .immediate
)
```

Immediate stop fails pending uplink work and closes downlink with an error.
Graceful stop stops uplink first and permits bounded provider output drain;
only a graceful outcome finishes downlink with normal end-of-stream. Stop
cleanup is shielded from cancellation of the calling task.

The optional OpenAI-specific transfer observer runs synchronously on the main
actor and never receives message content. Uplink facts cover successful
`session.update`, audio-append, and `session.close` text sends. Downlink facts
cover every successfully received text or data message before decoding,
including unknown or malformed messages. Authorization headers, pings, failed
socket completions, explicitly caller-cancelled sends, receive failures, and
callbacks from stale sessions do not produce facts. An audio append whose
socket completion succeeds during graceful drain is still observed even after
its channel caller has been released. A completed close outcome is a
transfer-observation barrier. The package does not buffer observations or
attribute them to a network; aggregation and network attribution remain
application responsibilities.

The independent OpenAI-specific audio-transfer observer also runs
synchronously on the main actor and never receives audio bytes or message
content. It reports media duration derived from the fixed 24 kHz mono PCM16
format, not wall-clock, playback, network, or billing duration. Uplink facts
follow only successful audio-append socket completions; downlink facts follow
successful decoding of valid, nonempty, frame-aligned translated PCM before
receiver delivery. A byte-transfer fact is reported first for the same wire
operation. Audio discarded without a subscriber is still observed, while
failed sends and invalid PCM are not. Pending successful audio and valid tail
audio remain observable during graceful drain; immediate cancellation,
replacement, terminal completion, and a returned close outcome are barriers
for stale callbacks. Supplying or omitting this observer does not change the
number or order of application-payload byte facts.

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
