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
public protocol SpeechProvider: Sendable {
    var capabilities: SpeechProviderCapabilities { get }

    /// Starts a session without prescribing authorization or transport mechanics.
    func startSession(
        _ configuration: SpeechSessionConfiguration
    ) async throws(SpeechProviderFailure) -> AsyncStream<SpeechEvent>

    /// Accepts PCM only through the shared audio-frame data plane.
    func consume(
        _ frame: AudioFrame,
        for sessionID: SpeechSessionID
    ) async throws(SpeechProviderFailure)

    func stopSession(_ sessionID: SpeechSessionID) async
}
