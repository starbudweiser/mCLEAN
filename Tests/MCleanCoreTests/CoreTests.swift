import XCTest
@testable import MCleanCore

final class CoreTests: XCTestCase {
    private let gb: UInt64 = 1_073_741_824

    private func snapshot(app: UInt64 = 8, wired: UInt64 = 4, compressed: UInt64 = 2, cached: UInt64 = 20, total: UInt64 = 64,
                          swap: UInt64 = 0, pressure: PressureLevel = .normal) -> MemorySnapshot {
        let c = VMCounters(pageSize: 16384, wired: wired * gb / 16384, compressor: compressed * gb / 16384,
                           internalPages: app * gb / 16384, externalPages: cached * gb / 16384, purgeable: 0)
        return MemorySnapshot(counters: c, total: total * gb, swapUsed: swap, pressure: pressure)
    }

    func testPartsAddUpToTotal() {
        let s = snapshot()
        XCTAssertEqual(s.app + s.wired + s.compressed + s.cached + s.free, s.total)
        XCTAssertEqual(s.available, 50 * gb)
        XCTAssertEqual(s.free, 30 * gb)
    }

    func testCacheNeverExceedsAvailable() {
        let s = snapshot(app: 30, wired: 10, compressed: 10, cached: 40, total: 64)
        XCTAssertEqual(s.cached, 14 * gb)
        XCTAssertEqual(s.free, 0)
    }

    func testUsedBeyondTotalDoesNotUnderflow() {
        let s = snapshot(app: 60, wired: 10, compressed: 10, cached: 5, total: 64)
        XCTAssertEqual(s.available, 0)
        XCTAssertEqual(s.usedFraction, 1)
    }

    func testPurgeableCountsAsCacheNotApp() {
        let c = VMCounters(pageSize: 1, wired: 0, compressor: 0, internalPages: 100, externalPages: 50, purgeable: 30)
        let s = MemorySnapshot(counters: c, total: 1000, swapUsed: 0, pressure: .normal)
        XCTAssertEqual(s.app, 70)
        XCTAssertEqual(s.cached, 80)
    }

    func testPlanTakesStepsUpToTarget() {
        let start = snapshot(cached: 1)
        let limits = CleanLimits.standard
        XCTAssertEqual(limits.next(start: start, now: start, allocated: 0, elapsed: 0), .allocate(gb / 2))
        XCTAssertEqual(limits.next(start: start, now: start, allocated: gb * 3 / 4, elapsed: 0), .allocate(gb / 4))
        XCTAssertEqual(limits.next(start: start, now: start, allocated: gb, elapsed: 0), .stop(.done))
    }

    func testPlanStopsOnEverySignOfStress() {
        let start = snapshot()
        let l = CleanLimits.standard
        XCTAssertEqual(l.next(start: start, now: snapshot(pressure: .warning), allocated: 0, elapsed: 0), .stop(.pressure))
        XCTAssertEqual(l.next(start: start, now: snapshot(swap: gb), allocated: 0, elapsed: 0), .stop(.swap))
        XCTAssertEqual(l.next(start: start, now: snapshot(compressed: 3), allocated: 0, elapsed: 0), .stop(.compression))
        XCTAssertEqual(l.next(start: start, now: snapshot(app: 60, wired: 2, compressed: 2), allocated: 0, elapsed: 0), .stop(.reserve))
        XCTAssertEqual(l.next(start: start, now: start, allocated: 0, elapsed: 21), .stop(.timeLimit))
    }

    func testPlanNeverCrossesReserve() {
        let start = snapshot(compressed: 2)
        let now = snapshot(app: 59, wired: 1, compressed: 2) // 2,0 Go de disponibles : la réserve
        XCTAssertEqual(CleanLimits.standard.next(start: start, now: now, allocated: 0, elapsed: 0), .stop(.reserve))
        let near = snapshot(app: 58, wired: 1, compressed: 2) // 3 Go : un palier normal reste possible
        XCTAssertEqual(CleanLimits.standard.next(start: start, now: near, allocated: 0, elapsed: 0), .allocate(gb / 2))
    }

    func testDeepAimsBeyondCache() {
        let s = snapshot(app: 8, cached: 20)
        XCTAssertEqual(CleanLimits.standard.target(from: s), 20 * gb)
        XCTAssertEqual(CleanLimits.deep.target(from: s), 22 * gb)
    }

    func testFreedIsGainInFreeMemory() {
        let before = snapshot(cached: 30), after = snapshot(cached: 10)
        XCTAssertEqual(CleanResult(kind: .standard, before: before, after: after, stop: .done, duration: 1).freed, 20 * gb)
        XCTAssertEqual(CleanResult(kind: .standard, before: after, after: before, stop: .done, duration: 1).freed, 0)
    }

    func testAutoCleanRules() {
        var s = AppSettings()
        s.autoClean = true
        s.thresholdGB = 8
        let low = snapshot(app: 50, wired: 5, compressed: 4, cached: 2)
        let now = Date()
        XCTAssertTrue(shouldAutoClean(settings: s, snapshot: low, lastRun: nil, now: now, busy: false))
        XCTAssertFalse(shouldAutoClean(settings: s, snapshot: snapshot(), lastRun: nil, now: now, busy: false))
        XCTAssertFalse(shouldAutoClean(settings: s, snapshot: low, lastRun: nil, now: now, busy: true))
        XCTAssertFalse(shouldAutoClean(settings: s, snapshot: low, lastRun: now.addingTimeInterval(-60), now: now, busy: false))
        XCTAssertTrue(shouldAutoClean(settings: s, snapshot: low, lastRun: now.addingTimeInterval(-3600), now: now, busy: false))
        var underPressure = low
        underPressure.pressure = .warning
        XCTAssertFalse(shouldAutoClean(settings: s, snapshot: underPressure, lastRun: nil, now: now, busy: false))
        s.autoClean = false
        XCTAssertFalse(shouldAutoClean(settings: s, snapshot: low, lastRun: nil, now: now, busy: false))
    }

    func testInactiveRules() {
        let now = Date()
        let old = AppActivity(bundleID: "a.b", lastActive: now.addingTimeInterval(-4 * 3600))
        XCTAssertTrue(isInactive(old, hours: 3, ignored: [], frontmost: nil, now: now))
        XCTAssertFalse(isInactive(old, hours: 5, ignored: [], frontmost: nil, now: now))
        XCTAssertFalse(isInactive(old, hours: 3, ignored: ["a.b"], frontmost: nil, now: now))
        XCTAssertFalse(isInactive(old, hours: 3, ignored: [], frontmost: "a.b", now: now))
        XCTAssertFalse(isInactive(AppActivity(bundleID: "com.apple.finder", lastActive: old.lastActive), hours: 3, ignored: [], frontmost: nil, now: now))
    }

    func testSettingsSurviveCorruptionAndMissingKeys() throws {
        XCTAssertEqual(AppSettings.decode(Data("oups".utf8)), AppSettings())
        XCTAssertEqual(AppSettings.decode(nil), AppSettings())
        let partial = AppSettings.decode(Data(#"{"autoClean":true,"refreshSeconds":9999}"#.utf8))
        XCTAssertTrue(partial.autoClean)
        XCTAssertEqual(partial.refreshSeconds, 60)
        XCTAssertEqual(partial.inactiveHours, AppSettings().inactiveHours)
        var s = AppSettings()
        s.ignoredBundleIDs = ["x"]
        XCTAssertEqual(AppSettings.decode(try JSONEncoder().encode(s)), s)
    }

    func testRealProbeIsCoherent() throws {
        let s = try XCTUnwrap(MemoryProbe.snapshot())
        XCTAssertGreaterThan(s.total, 0)
        XCTAssertGreaterThan(s.wired, 0)
        XCTAssertEqual(s.app + s.wired + s.compressed + s.cached + s.free, max(s.total, s.used + s.cached + s.free))
        XCTAssertFalse(MemoryProbe.footprintsByResponsiblePID().isEmpty)
    }
}
