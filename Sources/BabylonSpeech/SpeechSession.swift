import BabylonAudio
import Foundation

public struct SpeechSessionID: Hashable, Sendable {
    public let rawValue: UUID
    public let audioFlowID: AudioFlowID

    public init(rawValue: UUID = UUID(), audioFlowID: AudioFlowID) {
        self.rawValue = rawValue
        self.audioFlowID = audioFlowID
    }

    public func accepts(audioFlowID: AudioFlowID) -> Bool {
        self.audioFlowID == audioFlowID
    }

    @available(iOS 18, macOS 13, *)
    public func accepts(frame: AudioFrame) -> Bool {
        accepts(audioFlowID: frame.flowID)
    }
}

public struct SpeechLanguageTag: Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty,
              scalars.count <= 63,
              value.first != "-",
              value.last != "-",
              !value.contains("--"),
              scalars.allSatisfy(Self.isAllowed)
        else {
            throw SpeechContractError.invalidLanguageTag
        }
        self.value = value
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 45, 48...57, 65...90, 97...122:
            true
        default:
            false
        }
    }
}

public enum SpeechLanguagePreference: Equatable, Sendable {
    case automatic
    case language(SpeechLanguageTag)
}

public enum SpeechFeature: Hashable, Sendable {
    case transcription
    case translation
}

public struct SpeechSessionConfiguration: Equatable, Sendable {
    public let sessionID: SpeechSessionID
    public let features: Set<SpeechFeature>
    public let sourceLanguage: SpeechLanguagePreference
    public let targetLanguage: SpeechLanguageTag?

    public init(
        sessionID: SpeechSessionID,
        features: Set<SpeechFeature>,
        sourceLanguage: SpeechLanguagePreference,
        targetLanguage: SpeechLanguageTag? = nil
    ) throws {
        guard !features.isEmpty else {
            throw SpeechContractError.featureRequired
        }
        if features.contains(.translation) {
            guard targetLanguage != nil else {
                throw SpeechContractError.targetLanguageRequired
            }
        } else if targetLanguage != nil {
            throw SpeechContractError.targetLanguageNotUsed
        }

        self.sessionID = sessionID
        self.features = features
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

public enum SpeechContractError: Error, Equatable, Sendable {
    case invalidLanguageTag
    case featureRequired
    case targetLanguageRequired
    case targetLanguageNotUsed
    case invalidFailureIdentifier
}
