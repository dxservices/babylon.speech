# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

- Add the initial multi-product Swift package and test scaffold.
- Add provider-neutral speech session, event, capability, and safe-failure contracts.
- Replace direct provider audio consumption with session-bound event, uplink, and optional downlink channels.
- Add the public OpenAI Realtime translation provider with safe event mapping, session-bound 24 kHz PCM audio, deterministic transport liveness, and graceful close behavior.
- Add provider-neutral graceful and immediate session stop modes with content-free terminal outcomes while preserving the original graceful stop convenience.
- Add optional OpenAI-specific, content-free application-payload transfer facts with session and generation isolation while leaving aggregation and network attribution to the application.
- Add independent OpenAI-specific, content-free audio media-duration facts for successful PCM transfers without changing application-payload byte observations.
- Pin BabylonAudio to the exact remote `0.1.0` release and enforce provider-product boundary checks.
- Enforce English-only source, documentation, repository metadata, and reachable commit history.
