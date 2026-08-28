import Foundation

public struct OpenAIRealtimeAuthorization: Sendable {
    private let storage: Storage

    public init(clientSecret: String) {
        storage = Storage(clientSecret: clientSecret)
    }

    @discardableResult
    func apply(to request: inout URLRequest) -> Bool {
        guard !storage.clientSecret.isEmpty else { return false }
        request.setValue(
            "Bearer \(storage.clientSecret)",
            forHTTPHeaderField: "Authorization"
        )
        return true
    }

    private final class Storage: Sendable {
        let clientSecret: String

        init(clientSecret: String) {
            self.clientSecret = clientSecret
        }
    }
}
