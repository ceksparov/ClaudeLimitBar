import XCTest
@testable import ClaudeLimitBar

final class FormatDurationTests: XCTestCase {
    func testShowsSoonForZeroOrNegative() {
        XCTAssertEqual(formatDuration(0), "soon")
        XCTAssertEqual(formatDuration(-1000), "soon")
    }

    func testShowsMinutesOnly() {
        XCTAssertEqual(formatDuration(5 * 60_000), "5m")
    }

    func testShowsHoursAndMinutes() {
        XCTAssertEqual(formatDuration(2 * 3_600_000 + 15 * 60_000), "2h 15m")
    }

    func testShowsDaysAndHours() {
        XCTAssertEqual(formatDuration(3 * 86_400_000 + 4 * 3_600_000), "3d 4h")
    }
}

final class ResetLabelTests: XCTestCase {
    func testNoResetAtAndZeroPercentMeansNoUsageYet() {
        XCTAssertEqual(resetLabel(percent: 0, resetAt: nil, isEstimate: false, now: Date()), "no usage yet")
    }

    func testNoResetAtAndNonZeroPercentMeansUnknown() {
        XCTAssertEqual(resetLabel(percent: 42, resetAt: nil, isEstimate: false, now: Date()), "unknown")
    }

    func testShortWindowHasNoClockTime() {
        let now = Date()
        let resetAt = now.addingTimeInterval(3 * 3600) // 3 hours out — same day
        XCTAssertEqual(resetLabel(percent: 50, resetAt: resetAt, isEstimate: false, now: now), "3h 0m")
    }

    func testLongWindowIncludesClockTime() {
        let now = Date()
        let resetAt = now.addingTimeInterval(3 * 86400) // 3 days out
        let label = resetLabel(percent: 50, resetAt: resetAt, isEstimate: false, now: now)
        XCTAssertTrue(label.hasPrefix("3d 0h ("), "expected a weekday/clock suffix, got: \(label)")
    }

    func testEstimateIsNoted() {
        let now = Date()
        let resetAt = now.addingTimeInterval(3600)
        XCTAssertEqual(resetLabel(percent: 50, resetAt: resetAt, isEstimate: true, now: now), "1h 0m (estimated)")
    }
}

final class WithoutGlitchesTests: XCTestCase {
    private func sample(_ fh: Int, at t: Double) -> RawSample {
        RawSample(t: t, u: RawUsage(fh: fh, sd: 0))
    }

    func testDropsAMomentaryZeroThatBouncesBackToTheSameLevel() {
        let samples = [sample(50, at: 0), sample(0, at: 1), sample(55, at: 2)]
        let cleaned = withoutGlitches(samples, key: \.fh)
        XCTAssertEqual(cleaned.map { $0.u.fh }, [50, 55])
    }

    func testKeepsARealResetWhereTheValueClimbsBackUpSlowly() {
        let samples = [sample(90, at: 0), sample(0, at: 1), sample(3, at: 2)]
        let cleaned = withoutGlitches(samples, key: \.fh)
        XCTAssertEqual(cleaned.map { $0.u.fh }, [90, 0, 3])
    }
}

final class EstimateResetTests: XCTestCase {
    private func sample(_ fh: Int, at t: Double) -> RawSample {
        RawSample(t: t, u: RawUsage(fh: fh, sd: 0))
    }

    func testReturnsNilWhenCurrentValueIsZero() {
        let samples = [sample(80, at: 0), sample(0, at: 1000)]
        XCTAssertNil(estimateReset(samples: samples, key: \.fh, windowMs: 100, now: 2000))
    }

    func testEstimatesFromTheMostRecentDecrease() {
        let windowMs = 5.0 * 60 * 60 * 1000
        let samples = [
            sample(80, at: 0),
            sample(10, at: 1000), // reset happened here
            sample(20, at: 2000),
        ]
        let resetAt = estimateReset(samples: samples, key: \.fh, windowMs: windowMs, now: 3000)
        XCTAssertEqual(resetAt, 1000 + windowMs)
    }

    func testReturnsNilOnceTheEstimatedResetIsInThePast() {
        let windowMs = 100.0
        let samples = [sample(80, at: 0), sample(10, at: 1000)]
        XCTAssertNil(estimateReset(samples: samples, key: \.fh, windowMs: windowMs, now: 5000))
    }
}
