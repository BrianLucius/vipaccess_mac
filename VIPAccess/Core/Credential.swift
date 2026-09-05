import Foundation

/// A VIP Access credential containing the identifier and TOTP secret.
public struct Credential {
    /// The credential identifier (e.g., "SYMC12345678").
    public let id: String
    /// The raw secret bytes used for TOTP generation.
    public let secret: Data
    /// The base32-encoded representation of the secret.
    public let secretBase32: String

    public init(id: String, secret: Data, secretBase32: String) {
        self.id = id
        self.secret = secret
        self.secretBase32 = secretBase32
    }
}
