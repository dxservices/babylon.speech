public enum SpeechProviderFailureClassification: Equatable, Sendable {
    case invalidSession
    case sessionExpired
    case credential
    case network
    case rateLimited
    case unsupportedConfiguration
    case provider
}

public struct SpeechFailureIdentifier: Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty,
              scalars.count <= 64,
              scalars.allSatisfy(Self.isAllowed)
        else {
            throw SpeechContractError.invalidFailureIdentifier
        }
        self.value = value
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 45, 46, 48...57, 65...90, 95, 97...122:
            true
        default:
            false
        }
    }
}

public struct SpeechProviderFailure: Error, Equatable, Sendable {
    public let classification: SpeechProviderFailureClassification
    public let type: SpeechFailureIdentifier
    public let code: SpeechFailureIdentifier?

    public init(
        classification: SpeechProviderFailureClassification,
        type: SpeechFailureIdentifier,
        code: SpeechFailureIdentifier?
    ) {
        self.classification = classification
        self.type = type
        self.code = code
    }
}
