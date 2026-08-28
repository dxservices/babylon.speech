import Foundation

/// Caller-injected authorization for one or more OpenAI Realtime connections.
///
/// Supply an app-owned, short-lived Realtime client secret. Do not pass a
/// long-lived server API key. The package holds the value in memory for request
/// authorization; it does not acquire, refresh, persist, or log credentials.
public struct OpenAIRealtimeAuthorization: Sendable {
    private let storage: Storage

    /// Creates authorization from a caller-supplied Realtime client secret.
    ///
    /// - Parameter clientSecret: A short-lived client secret supplied by the
    ///   application.
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
