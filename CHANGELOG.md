# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

- Add the initial multi-product Swift package and test scaffold.
- Add provider-neutral speech session, event, capability, and safe-failure contracts.
- Replace direct provider audio consumption with session-bound event, uplink, and optional downlink channels.
- Add the public OpenAI Realtime translation provider with safe event mapping, session-bound 24 kHz PCM audio, deterministic transport liveness, and graceful close behavior.
- Pin BabylonAudio to the exact remote `0.1.0` release and enforce provider-product boundary checks.
- Enforce English-only source, documentation, repository metadata, and reachable commit history.
