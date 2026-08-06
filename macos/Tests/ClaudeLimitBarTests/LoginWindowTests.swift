import XCTest
@testable import ClaudeLimitBar

// isClaudeDomain gates which cookie captureSessionKey will even attempt to
// validate as a session key. These cases are the actual attack shapes a
// substring check ("contains") would have let through — each of these
// domains contains "claude.ai" as a substring while belonging to a
// different registrable domain entirely.
final class IsClaudeDomainTests: XCTestCase {
    func testAcceptsTheExactDomain() {
        XCTAssertTrue(isClaudeDomain("claude.ai"))
    }

    func testAcceptsARealSubdomain() {
        XCTAssertTrue(isClaudeDomain("accounts.claude.ai"))
    }

    // RFC 6265 domain cookies are set with a leading dot.
    func testAcceptsTheLeadingDotForm() {
        XCTAssertTrue(isClaudeDomain(".claude.ai"))
        XCTAssertTrue(isClaudeDomain(".accounts.claude.ai"))
    }

    // The exact shape called out in the code comment: claude.ai appears as
    // a substring, but the registrable domain is attacker-controlled.
    func testRejectsClaudeAiAsATrailingSubstring() {
        XCTAssertFalse(isClaudeDomain("notclaude.ai.example.com"))
        XCTAssertFalse(isClaudeDomain("evilclaude.ai"))
    }

    // The other direction: claude.ai as a PREFIX of an attacker domain.
    func testRejectsClaudeAiAsALeadingSubstring() {
        XCTAssertFalse(isClaudeDomain("claude.ai.attacker.com"))
    }

    func testRejectsAnUnrelatedDomain() {
        XCTAssertFalse(isClaudeDomain("example.com"))
    }

    func testRejectsEmptyString() {
        XCTAssertFalse(isClaudeDomain(""))
    }
}
