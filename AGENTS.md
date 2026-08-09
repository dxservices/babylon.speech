# Repository instructions

## Scope

BabylonSpeech is a provider-neutral real-time speech-intelligence package built on BabylonAudio. Keep application UI, credential acquisition, business recovery policy, product state, device management, audio buffering, and persistence outside this repository.

## Engineering rules

- Target iOS 18 or later and use Swift 6 language mode with strict concurrency.
- Keep provider dependencies inside their corresponding adapter targets.
- Keep the neutral target free of provider names, wire protocols, networking assumptions, and credential requirements.
- Send PCM through BabylonAudio rather than through speech-event streams.
- Isolate stale callbacks and events by audio-flow and speech-session identity.
- Expose structured safe failure classifications and type/code values only.
- Never persist or log raw audio, transcripts, credentials, provider payloads, or full error bodies.
- Write all repository documentation, comments, tests, and commit messages in English.
- Add a failing behavioral test before implementation changes.

## Verification

Run `swift test`, `swift build`, and `python3 Scripts/check_repository.py`. Real provider behavior requires separate integration evidence with injected test credentials.

