import XCTest
@testable import ClaudeLimitBar

final class ParseTimestampTests: XCTestCase {
    func testParsesTimestampWithMicrosecondPrecision() {
        let date = UsageAPI.parseTimestamp("2026-07-31T11:10:00.271661+00:00")
        XCTAssertNotNil(date)
    }

    func testParsesTimestampWithZSuffix() {
        let date = UsageAPI.parseTimestamp("2026-07-31T11:10:00.123456Z")
        XCTAssertNotNil(date)
    }

    func testReturnsNilForGarbage() {
        XCTAssertNil(UsageAPI.parseTimestamp("not a timestamp"))
    }
}
