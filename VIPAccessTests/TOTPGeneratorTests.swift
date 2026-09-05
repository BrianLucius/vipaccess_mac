import XCTest
@testable import VIPAccess

final class TOTPGeneratorTests: XCTestCase {

    // MARK: - RFC 6238 Appendix B Test Vectors (SHA1, 8 digits, period 30)

    /// The RFC 6238 test secret for HMAC-SHA1 is the ASCII string "12345678901234567890" (20 bytes).
    private var rfcSecret: Data {
        Data("12345678901234567890".utf8)
    }

    func testRFC6238Vector_time59() {
        let generator = TOTPGenerator(secret: rfcSecret, period: 30, digits: 8)
        let date = Date(timeIntervalSince1970: 59)
        XCTAssertEqual(generator.generateCode(at: date), "94287082")
    }

    func testRFC6238Vector_time1111111109() {
        let generator = TOTPGenerator(secret: rfcSecret, period: 30, digits: 8)
        let date = Date(timeIntervalSince1970: 1111111109)
        XCTAssertEqual(generator.generateCode(at: date), "07081804")
    }

    func testRFC6238Vector_time1111111111() {
        let generator = TOTPGenerator(secret: rfcSecret, period: 30, digits: 8)
        let date = Date(timeIntervalSince1970: 1111111111)
        XCTAssertEqual(generator.generateCode(at: date), "14050471")
    }

    func testRFC6238Vector_time1234567890() {
        let generator = TOTPGenerator(secret: rfcSecret, period: 30, digits: 8)
        let date = Date(timeIntervalSince1970: 1234567890)
        XCTAssertEqual(generator.generateCode(at: date), "89005924")
    }

    func testRFC6238Vector_time2000000000() {
        let generator = TOTPGenerator(secret: rfcSecret, period: 30, digits: 8)
        let date = Date(timeIntervalSince1970: 2000000000)
        XCTAssertEqual(generator.generateCode(at: date), "69279037")
    }

    func testRFC6238Vector_time20000000000() {
        let generator = TOTPGenerator(secret: rfcSecret, period: 30, digits: 8)
        let date = Date(timeIntervalSince1970: 20000000000)
        XCTAssertEqual(generator.generateCode(at: date), "65353130")
    }

    // MARK: - 6-digit truncation (default configuration)

    /// Verify the default 6-digit output produces the last 6 digits of the 8-digit code.
    func testSixDigitTruncation() {
        let generator = TOTPGenerator(secret: rfcSecret, period: 30, digits: 6)
        let date = Date(timeIntervalSince1970: 59)
        // 8-digit code is "94287082", so 6-digit truncation should yield "287082"
        XCTAssertEqual(generator.generateCode(at: date), "287082")
    }

    // MARK: - secondsRemaining

    func testSecondsRemaining_startOfPeriod() {
        let generator = TOTPGenerator(secret: rfcSecret, period: 30, digits: 6)
        // At time 60, elapsed in period = 60 % 30 = 0, so remaining = 30
        let date = Date(timeIntervalSince1970: 60)
        XCTAssertEqual(generator.secondsRemaining(at: date), 30)
    }

    func testSecondsRemaining_midPeriod() {
        let generator = TOTPGenerator(secret: rfcSecret, period: 30, digits: 6)
        // At time 75, elapsed in period = 75 % 30 = 15, so remaining = 15
        let date = Date(timeIntervalSince1970: 75)
        XCTAssertEqual(generator.secondsRemaining(at: date), 15)
    }

    func testSecondsRemaining_endOfPeriod() {
        let generator = TOTPGenerator(secret: rfcSecret, period: 30, digits: 6)
        // At time 89, elapsed in period = 89 % 30 = 29, so remaining = 1
        let date = Date(timeIntervalSince1970: 89)
        XCTAssertEqual(generator.secondsRemaining(at: date), 1)
    }

    // MARK: - nextCode

    func testNextCode_returnsCodeForNextPeriod() {
        let generator = TOTPGenerator(secret: rfcSecret, period: 30, digits: 8)
        // At time 59, counter = 59/30 = 1. nextCode should use counter = 2.
        // Time 60 falls in counter = 2, so generateCode(at: 60) == nextCode(at: 59)
        let date = Date(timeIntervalSince1970: 59)
        let nextDate = Date(timeIntervalSince1970: 60)
        XCTAssertEqual(generator.nextCode(at: date), generator.generateCode(at: nextDate))
    }

    func testNextCode_matchesRFCVectorForSubsequentPeriod() {
        let generator = TOTPGenerator(secret: rfcSecret, period: 30, digits: 8)
        // time 1111111109 → counter = 37037036. nextCode should use counter 37037037.
        // time 1111111111 → counter = 37037037. So nextCode(at: 1111111109) == generateCode(at: 1111111111)
        let date = Date(timeIntervalSince1970: 1111111109)
        let nextPeriodDate = Date(timeIntervalSince1970: 1111111111)
        // Both 1111111109 and 1111111111 are in different periods:
        // 1111111109 / 30 = 37037036 (floor), 1111111111 / 30 = 37037037 (floor)
        XCTAssertEqual(generator.nextCode(at: date), generator.generateCode(at: nextPeriodDate))
    }

    // MARK: - oathtool --totp Cross-Verification
    //
    // These tests verify that our TOTPGenerator produces identical output to
    // `oathtool --totp` from oath-toolkit (https://www.nongnu.org/oath-toolkit/).
    //
    // Manual verification (requires `brew install oath-toolkit`):
    //   oathtool --totp -b --digits=8 "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" --now "1970-01-01 00:00:59 UTC"
    //   → 94287082
    //
    //   oathtool --totp -b --digits=6 "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" --now "1970-01-01 00:00:59 UTC"
    //   → 287082
    //
    //   oathtool --totp -b --digits=6 "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" --now "2009-02-13 23:31:30 UTC"
    //   → 005924
    //
    // The base32 secret "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" decodes to "12345678901234567890" (20 bytes).

    /// Runs `oathtool` as a subprocess and returns the trimmed output, or nil if oathtool is not available.
    private func runOathtool(args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/oathtool")

        // Fallback to /usr/local/bin/oathtool for Intel Macs
        if !FileManager.default.fileExists(atPath: "/opt/homebrew/bin/oathtool") {
            if FileManager.default.fileExists(atPath: "/usr/local/bin/oathtool") {
                process.executableURL = URL(fileURLWithPath: "/usr/local/bin/oathtool")
            } else {
                return nil // oathtool not installed
            }
        }

        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Cross-verify our 8-digit output at RFC test vector timestamps against oathtool.
    func testOathtoolCrossVerification_8digits() throws {
        let base32Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let generator = TOTPGenerator(secret: rfcSecret, period: 30, digits: 8)

        let testCases: [(timestamp: TimeInterval, dateString: String, expected: String)] = [
            (59,          "1970-01-01 00:00:59 UTC", "94287082"),
            (1234567890,  "2009-02-13 23:31:30 UTC", "89005924"),
            (2000000000,  "2033-05-18 03:33:20 UTC", "69279037"),
        ]

        for testCase in testCases {
            // Get our implementation's output
            let ourCode = generator.generateCode(at: Date(timeIntervalSince1970: testCase.timestamp))
            XCTAssertEqual(ourCode, testCase.expected, "Our code at T=\(testCase.timestamp) should match expected")

            // Get oathtool's output
            let oathResult = runOathtool(args: [
                "--totp", "-b", "--digits=8", base32Secret,
                "--now", testCase.dateString
            ])

            // If oathtool is available, verify outputs match
            if let oathCode = oathResult {
                XCTAssertEqual(
                    ourCode, oathCode,
                    "TOTPGenerator output '\(ourCode)' should match oathtool output '\(oathCode)' at T=\(testCase.timestamp)"
                )
            } else {
                // oathtool not installed — skip live comparison but test still passes
                // because we verified against the expected RFC vectors above
                print("⚠️ oathtool not available — skipping live cross-verification for T=\(testCase.timestamp)")
            }
        }
    }

    /// Cross-verify our 6-digit output against oathtool (the default production configuration).
    func testOathtoolCrossVerification_6digits() throws {
        let base32Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let generator = TOTPGenerator(secret: rfcSecret, period: 30, digits: 6)

        let testCases: [(timestamp: TimeInterval, dateString: String, expected: String)] = [
            (59,          "1970-01-01 00:00:59 UTC", "287082"),
            (1234567890,  "2009-02-13 23:31:30 UTC", "005924"),
            (2000000000,  "2033-05-18 03:33:20 UTC", "279037"),
        ]

        for testCase in testCases {
            let ourCode = generator.generateCode(at: Date(timeIntervalSince1970: testCase.timestamp))
            XCTAssertEqual(ourCode, testCase.expected, "Our 6-digit code at T=\(testCase.timestamp) should match expected")

            let oathResult = runOathtool(args: [
                "--totp", "-b", "--digits=6", base32Secret,
                "--now", testCase.dateString
            ])

            if let oathCode = oathResult {
                XCTAssertEqual(
                    ourCode, oathCode,
                    "TOTPGenerator 6-digit output '\(ourCode)' should match oathtool output '\(oathCode)' at T=\(testCase.timestamp)"
                )
            } else {
                print("⚠️ oathtool not available — skipping live cross-verification for T=\(testCase.timestamp)")
            }
        }
    }
}
