import Foundation
import CommonCrypto

/// Generates TOTP codes per RFC 6238 using HMAC-SHA1.
public struct TOTPGenerator {
    /// The shared secret (raw bytes).
    public let secret: Data
    /// Time step in seconds (default 30).
    public let period: Int
    /// Number of digits in the output code (default 6).
    public let digits: Int

    public init(secret: Data, period: Int = 30, digits: Int = 6) {
        self.secret = secret
        self.period = period
        self.digits = digits
    }

    /// Returns the TOTP code for the given timestamp.
    public func generateCode(at date: Date = .now) -> String {
        let counter = Self.counter(for: date, period: period)
        return generateCode(for: counter)
    }

    /// Returns the TOTP code for the NEXT time period after the given timestamp.
    public func nextCode(at date: Date = .now) -> String {
        let counter = Self.counter(for: date, period: period) + 1
        return generateCode(for: counter)
    }

    /// Returns the number of seconds remaining until the current code expires (0 to period-1).
    public func secondsRemaining(at date: Date = .now) -> Int {
        let unixTime = Int(date.timeIntervalSince1970)
        let elapsed = unixTime % period
        return period - elapsed
    }

    // MARK: - Private

    private static func counter(for date: Date, period: Int) -> UInt64 {
        let unixTime = UInt64(date.timeIntervalSince1970)
        return unixTime / UInt64(period)
    }

    private func generateCode(for counter: UInt64) -> String {
        // Step 1: Convert counter to big-endian 8 bytes
        var counterBigEndian = counter.bigEndian
        let counterData = Data(bytes: &counterBigEndian, count: MemoryLayout<UInt64>.size)

        // Step 2: Compute HMAC-SHA1
        let hmac = hmacSHA1(key: secret, message: counterData)

        // Step 3: Dynamic truncation (RFC 4226 Section 5.4)
        let offset = Int(hmac[19] & 0x0F)
        let truncated: UInt32 = (UInt32(hmac[offset]) & 0x7F) << 24
            | UInt32(hmac[offset + 1]) << 16
            | UInt32(hmac[offset + 2]) << 8
            | UInt32(hmac[offset + 3])

        // Step 4: Compute code
        let mod = truncated % UInt32(pow(10.0, Double(digits)))

        // Step 5: Zero-pad to the requested number of digits
        return String(format: "%0\(digits)d", mod)
    }

    private func hmacSHA1(key: Data, message: Data) -> [UInt8] {
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            message.withUnsafeBytes { msgPtr in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA1),
                    keyPtr.baseAddress, key.count,
                    msgPtr.baseAddress, message.count,
                    &hmac
                )
            }
        }
        return hmac
    }
}
