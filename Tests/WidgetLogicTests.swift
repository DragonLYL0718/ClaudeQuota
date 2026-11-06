import XCTest

final class WidgetLogicTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func account(id: String = "account") -> AccountSnapshot {
        AccountSnapshot(id: id, service: .claude, name: id, status: .ok,
                        primary: UsageWindow(label: "five_hour", percent: 50,
                                             resetsAt: now.addingTimeInterval(4 * 3600),
                                             seconds: UsageWindow.fiveHours),
                        secondary: UsageWindow(label: "seven_day", percent: 100,
                                               resetsAt: now.addingTimeInterval(3 * 86400),
                                               seconds: UsageWindow.week),
                        updatedAt: now)
    }

    func testExhaustedWeeklyWindowTakesPrecedenceOverFastPrimary() {
        let result = PaceStatus(account: account(), now: now, lang: .en)
        XCTAssertEqual(result.kind, .exhausted)
        XCTAssertEqual(result.text, "Week limit used up")
    }

    func testPaceSelectsTheSoonestExhaustionAcrossWindows() {
        var value = account()
        value.primary?.percent = 70 // About 26 minutes remaining at the current rate.
        value.secondary?.percent = 99.9 // About 6 minutes remaining.
        let result = PaceStatus(account: value, now: now, lang: .en)
        XCTAssertEqual(result.kind, .fast)
        XCTAssertTrue(result.text.hasPrefix("Week runs out"))
    }

    func testPaceIsUnavailableForFailedStaleMissingAndExpiredObservations() {
        var value = account()
        value.status = .error
        XCTAssertEqual(PaceStatus(account: value, now: now, lang: .en).kind, .unknown)
        value.status = .ok
        value.updatedAt = now.addingTimeInterval(-20 * 60)
        XCTAssertEqual(PaceStatus(account: value, now: now, lang: .en).kind, .unknown)
        value.updatedAt = now
        value.primary?.resetsAt = now
        value.secondary?.resetsAt = now.addingTimeInterval(-1)
        XCTAssertEqual(PaceStatus(account: value, now: now, lang: .en).kind, .unknown)
        value.primary = nil
        value.secondary = nil
        XCTAssertEqual(PaceStatus(account: value, now: now, lang: .en).kind, .unknown)
    }

    func testLowUsageWithCurrentDataRemainsOnTrack() {
        var value = account()
        value.primary?.percent = 1
        value.secondary?.percent = 1
        XCTAssertEqual(PaceStatus(account: value, now: now, lang: .en).kind, .normal)
    }

    func testStateDistinguishesCachedErrorsMissingDataAndStaleness() {
        var value = account()
        XCTAssertEqual(value.displayState(at: now), .current)
        value.status = .error
        XCTAssertEqual(value.displayState(at: now), .error)
        XCTAssertTrue(value.hasData)
        value.status = .needsLogin
        XCTAssertEqual(value.displayState(at: now), .needsLogin)
        value.status = .ok
        XCTAssertEqual(value.displayState(at: now.addingTimeInterval(20 * 60)), .stale)
        value.updatedAt = nil
        XCTAssertEqual(value.displayState(at: now), .stale)
        value.primary = nil
        value.secondary = nil
        XCTAssertEqual(value.displayState(at: now), .noData)
    }

    func testHeaderUsesOldestSuccessfulObservationAndKeepsFailureVisible() {
        let fresh = account(id: "fresh")
        var failed = account(id: "failed")
        failed.status = .error
        failed.updatedAt = now.addingTimeInterval(-3600)
        let result = WidgetFreshness(accounts: [fresh, failed], now: now)
        XCTAssertEqual(result.oldestSuccess, failed.updatedAt)
        XCTAssertEqual(result.state, .error)
    }

    func testAnUninitializedAccountDoesNotInheritAnotherAccountsFreshness() {
        var missing = account(id: "missing")
        missing.primary = nil
        missing.secondary = nil
        missing.updatedAt = nil
        XCTAssertEqual(WidgetFreshness(accounts: [account(), missing], now: now).state, .noData)
    }

    func testDeletedExplicitSelectionNeverShowsUnselectedAccounts() {
        let values = [account(id: "personal"), account(id: "work")]
        XCTAssertTrue(WidgetAccountSelection.resolve(values, chosen: ["deleted"]).isEmpty)
        XCTAssertEqual(WidgetAccountSelection.resolve(values, chosen: []).map(\.id), ["personal", "work"])
        XCTAssertEqual(WidgetAccountSelection.resolve(values, chosen: ["work", "deleted"]).map(\.id), ["work"])
    }

    func testTimelineCoalescesNearbyTransitionsAndIncludesStaleBoundary() {
        var value = account()
        value.primary?.resetsAt = now.addingTimeInterval(60)
        value.secondary?.resetsAt = now.addingTimeInterval(90)
        let dates = WidgetTimelineSchedule.dates(accounts: [value], now: now)
        XCTAssertEqual(dates.first, now)
        XCTAssertTrue(dates.contains(now.addingTimeInterval(20 * 60)))
        XCTAssertTrue(zip(dates, dates.dropFirst()).allSatisfy { $1.timeIntervalSince($0) >= 5 * 60 })
        XCTAssertLessThan(dates.count, 20)
    }

    func testRefreshRevisionRecognizesTwoRefreshesWithinTheSameSecond() {
        let before = QuotaSnapshot(accounts: [], generatedAt: now, refreshRevision: "first")
        let after = QuotaSnapshot(accounts: [], generatedAt: now, refreshRevision: "second")
        XCTAssertTrue(WidgetRefreshSignal.advanced(from: before, to: after))
        XCTAssertFalse(WidgetRefreshSignal.advanced(from: before, to: before))
        XCTAssertFalse(WidgetRefreshSignal.advanced(from: before, to: nil))
    }

    func testRefreshSignalRemainsCompatibleWithSnapshotsWithoutARevision() {
        let before = QuotaSnapshot(accounts: [], generatedAt: now)
        let after = QuotaSnapshot(accounts: [], generatedAt: now.addingTimeInterval(1))
        XCTAssertTrue(WidgetRefreshSignal.advanced(from: before, to: after))
        XCTAssertFalse(WidgetRefreshSignal.advanced(from: before, to: before))
    }

    func testPagingPreservesOrderAndCapacityAcrossSupportedCounts() {
        for count in 0...8 {
            for capacity in [4, 6] {
                let values = Array(0..<count)
                let pages = Paging.pages(values, capacity: capacity)
                XCTAssertEqual(pages.flatMap { $0 }, values)
                XCTAssertTrue(pages.allSatisfy { $0.count <= capacity })
                XCTAssertLessThanOrEqual((pages.map(\.count).max() ?? 0) - (pages.map(\.count).min() ?? 0), 1)
            }
        }
    }

    func testFormattingRejectsNonfiniteAndUnrepresentableNumbers() {
        for value in [Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude, Double(Int.max)] {
            XCTAssertEqual(Format.percent(value), "—")
            XCTAssertEqual(Format.duration(value, lang: .en), "Unknown")
            XCTAssertEqual(Format.money(value, currency: "USD"), "—")
        }
        XCTAssertEqual(Format.percent(-1), "—")
        XCTAssertEqual(Format.percent(99.5), "100%")
        XCTAssertEqual(Format.percent(0), "0%")
        XCTAssertEqual(Format.duration(3600, lang: .en), "1:00")
    }

    func testFormattingRejectsUnrepresentableDatesAndWindowLengths() {
        let invalid = Date(timeIntervalSince1970: Double.greatestFiniteMagnitude)
        XCTAssertEqual(Format.countdown(to: invalid, from: now, lang: .en), "Unknown")
        XCTAssertEqual(Format.resetPhrase(to: invalid, from: now, lang: .en), "Reset time unknown")
        XCTAssertEqual(Format.weekdayTime(invalid, lang: .en), "Unknown")
        XCTAssertEqual(Format.updated(invalid, from: now, lang: .en), "Update time unknown")
        XCTAssertEqual(Format.windowName(Double.greatestFiniteMagnitude, lang: .en), "Unknown")
        XCTAssertEqual(Format.windowName(0, lang: .en), "Unknown")
    }

    func testSecondaryOnlyUsesItsRealWindowForTheMainRing() {
        var value = account()
        value.primary = nil
        value.secondary?.percent = 73
        XCTAssertEqual(value.displayPrimary?.percent, 73)
        XCTAssertEqual(value.displayPrimary?.seconds, UsageWindow.week)
        XCTAssertNil(value.displaySecondary)
        XCTAssertTrue(value.showsNumbers)
    }

    func testDetailsOnlyShowsItsHighestModelRatherThanAnEmptyRing() {
        var value = account()
        value.primary = nil
        value.secondary = nil
        value.models = [UsageWindow(label: "Sonnet", percent: 20, seconds: UsageWindow.week),
                        UsageWindow(label: "Opus", percent: 96, seconds: UsageWindow.week)]
        XCTAssertEqual(value.displayState(at: now), .current)
        XCTAssertEqual(value.displayPrimary?.label, "Opus")
        XCTAssertEqual(value.displayPrimary?.percent, 96)
        XCTAssertEqual(value.peakPercent, 96)
        XCTAssertEqual(WidgetFreshness(accounts: [value], now: now).oldestSuccess, value.updatedAt)
    }

    func testExtraOnlyDisplaysSpendingUsageAndLoginStillHidesNumbers() {
        var value = account()
        value.primary = nil
        value.secondary = nil
        value.extra = ExtraUsage(used: 25, limit: 100, currency: "USD")
        XCTAssertEqual(value.displayPrimary?.label, "extra_usage")
        XCTAssertEqual(value.displayPrimary?.percent, 25)
        XCTAssertTrue(value.showsNumbers)
        value.status = .needsLogin
        XCTAssertFalse(value.showsNumbers)
    }
}
