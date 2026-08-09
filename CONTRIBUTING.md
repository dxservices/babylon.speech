# Contributing

BabylonSpeech is currently in pre-0.1 contract development. Public API stability is not guaranteed.

## Local checks

Run these checks before submitting a change:

```sh
swift package resolve
swift test
swift build
python3 Scripts/check_repository.py
```

All repository documentation, code comments, tests, and commit messages must be written in English.

Provider-neutral contracts require tests against at least OpenAI-shaped, Google-shaped, and in-process local-model fakes. A contract must not require network or credentials merely because one adapter does.

Never add raw audio, transcripts, credentials, provider payloads, full error bodies, personal signing data, or content-bearing logs to fixtures, diagnostics, screenshots, or commits.

