import BabylonAudio

public enum SpeechCredentialRequirement: Equatable, Sendable {
    case none
    case callerInjected
}

@available(iOS 18, macOS 13, *)
public struct SpeechProviderCapabilities: Equatable, Sendable {
    public let requiresNetwork: Bool
    public let credentialRequirement: SpeechCredentialRequirement
    public let supportedFeatures: Set<SpeechFeature>
    public let acceptedInputFormats: [AudioStreamFormat]
    public let outputAudioFormats: [AudioStreamFormat]
    public let supportsAutomaticSourceLanguage: Bool
    public let reportsDetectedSourceLanguage: Bool

    public var requiresCredential: Bool {
        credentialRequirement != .none
    }

    public init(
        requiresNetwork: Bool,
        credentialRequirement: SpeechCredentialRequirement,
        supportedFeatures: Set<SpeechFeature>,
        acceptedInputFormats: [AudioStreamFormat],
        outputAudioFormats: [AudioStreamFormat],
        supportsAutomaticSourceLanguage: Bool,
        reportsDetectedSourceLanguage: Bool
    ) {
        self.requiresNetwork = requiresNetwork
        self.credentialRequirement = credentialRequirement
        self.supportedFeatures = supportedFeatures
        self.acceptedInputFormats = acceptedInputFormats
        self.outputAudioFormats = outputAudioFormats
        self.supportsAutomaticSourceLanguage = supportsAutomaticSourceLanguage
        self.reportsDetectedSourceLanguage = reportsDetectedSourceLanguage
    }

    public func supports(_ configuration: SpeechSessionConfiguration) -> Bool {
        guard configuration.features.isSubset(of: supportedFeatures) else {
            return false
        }
        if case .automatic = configuration.sourceLanguage {
            return supportsAutomaticSourceLanguage
        }
        return true
    }

    public func accepts(inputFormat: AudioStreamFormat) -> Bool {
        acceptedInputFormats.contains(inputFormat)
    }
}

@available(iOS 18, macOS 13, *)
public struct SpeechSessionChannels: Sendable {
    public let sessionID: SpeechSessionID
    public let events: AsyncStream<SpeechEvent>
    /// The application injection point for session uplink PCM frames.
    public let uplink: any AudioFrameSender
    /// Session downlink PCM, when the provider produces audio.
    public let downlink: (any AudioFrameReceiver)?

    public init(
        sessionID: SpeechSessionID,
        events: AsyncStream<SpeechEvent>,
        uplink: any AudioFrameSender,
        downlink: (any AudioFrameReceiver)?
    ) {
        self.sessionID = sessionID
        self.events = Self.bind(events: events, to: sessionID)
        self.uplink = SessionBoundFrameSender(
            sessionID: sessionID,
            base: uplink
        )
        self.downlink = downlink.map {
            SessionBoundFrameReceiver(sessionID: sessionID, base: $0)
        }
    }

    private static func bind(
        events: AsyncStream<SpeechEvent>,
        to sessionID: SpeechSessionID
    ) -> AsyncStream<SpeechEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    guard !Task.isCancelled else { break }
                    if event.sessionID == sessionID {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum SpeechAudioChannelError: Error, Equatable, Sendable {
    case flowMismatch
}

@available(iOS 18, macOS 13, *)
private struct SessionBoundFrameSender: AudioFrameSender {
    let sessionID: SpeechSessionID
    let base: any AudioFrameSender

    func send(_ frame: AudioFrame) async throws {
        guard sessionID.accepts(frame: frame) else {
            throw SpeechAudioChannelError.flowMismatch
        }
        try await base.send(frame)
    }
}

@available(iOS 18, macOS 13, *)
private struct SessionBoundFrameReceiver: AudioFrameReceiver {
    let sessionID: SpeechSessionID
    let base: any AudioFrameReceiver

    func frames(
        for flowID: AudioFlowID
    ) -> AsyncThrowingStream<AudioFrame, any Error> {
        guard flowID == sessionID.audioFlowID else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: SpeechAudioChannelError.flowMismatch)
            }
        }

        let source = base.frames(for: flowID)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await frame in source {
                        guard !Task.isCancelled else { break }
                        guard sessionID.accepts(frame: frame) else {
                            throw SpeechAudioChannelError.flowMismatch
                        }
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@available(iOS 18, macOS 13, *)
public protocol SpeechProvider: Sendable {
    var capabilities: SpeechProviderCapabilities { get }

    /// Starts a session without prescribing authorization or transport mechanics.
    func startSession(
        _ configuration: SpeechSessionConfiguration
    ) async throws(SpeechProviderFailure) -> SpeechSessionChannels

    func stopSession(_ sessionID: SpeechSessionID) async
}
