import XCTest
@testable import MCleanCore

final class GuardTests: XCTestCase {
    private let gb: UInt64 = 1_073_741_824

    private func snapshot(used: UInt64, total: UInt64 = 64, pressure: PressureLevel = .normal) -> MemorySnapshot {
        let c = VMCounters(pageSize: 1, wired: 0, compressor: 0, internalPages: used * gb, externalPages: 0, purgeable: 0)
        return MemorySnapshot(counters: c, total: total * gb, swapUsed: 0, pressure: pressure)
    }

    func testLevelOkWithRoomToSpare() {
        XCTAssertEqual(guardLevel(snapshot(used: 30)), .ok)
    }

    func testLevelAlertWhenAvailableLow() {
        XCTAssertEqual(guardLevel(snapshot(used: 61)), .alert) // 3 Go libres sur 64 : sous 1/16
    }

    func testLevelEmergencyWhenAlmostNothingLeft() {
        XCTAssertEqual(guardLevel(snapshot(used: 63)), .emergency)
    }

    func testPressureAloneRaisesLevel() {
        XCTAssertEqual(guardLevel(snapshot(used: 30, pressure: .warning)), .alert)
        XCTAssertEqual(guardLevel(snapshot(used: 30, pressure: .critical)), .emergency)
    }

    func testSmallMachineKeepsAbsoluteFloor() {
        XCTAssertEqual(guardLevel(snapshot(used: 4, total: 8)), .ok)
        XCTAssertEqual(guardLevel(snapshot(used: 6, total: 8)), .alert) // 2 Go libres : sous le plancher d'alerte de 3 Go
        XCTAssertEqual(guardLevel(snapshot(used: 7, total: 8)), .emergency)
    }

    func testSustainedCPUIsFlaggedOnlyAfterDelay() {
        var t = GuardTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        func s(_ seconds: Double) -> [ProcessSample] { [ProcessSample(pid: 10, group: 10, footprint: 0, cpuNanos: UInt64(seconds * 1e9))] }
        XCTAssertTrue(t.ingest(s(0), now: t0).cpuHogs.isEmpty)
        XCTAssertTrue(t.ingest(s(10), now: t0 + 10).cpuHogs.isEmpty)   // 100 % d'un cœur, mais depuis 10 s seulement
        XCTAssertTrue(t.ingest(s(20), now: t0 + 20).cpuHogs.isEmpty)
        XCTAssertEqual(t.ingest(s(30), now: t0 + 30).cpuHogs, [10])
    }

    func testCPUBurstResetsTheClock() {
        var t = GuardTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        func s(_ seconds: Double) -> [ProcessSample] { [ProcessSample(pid: 10, group: 10, footprint: 0, cpuNanos: UInt64(seconds * 1e9))] }
        _ = t.ingest(s(0), now: t0)
        _ = t.ingest(s(10), now: t0 + 10)
        _ = t.ingest(s(10.5), now: t0 + 20)  // calme : l'horloge repart
        _ = t.ingest(s(20), now: t0 + 30)
        XCTAssertTrue(t.ingest(s(30), now: t0 + 40).cpuHogs.isEmpty)
    }

    func testLightProcessIsNeverFlagged() {
        var t = GuardTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        for i in 0...10 {
            let p = ProcessSample(pid: 5, group: 5, footprint: 0, cpuNanos: UInt64(Double(i) * 1e9)) // 10 % d'un cœur
            XCTAssertTrue(t.ingest([p], now: t0 + Double(i) * 10).cpuHogs.isEmpty)
        }
    }

    func testRunawayMemoryIsDetectedPerApp() {
        var t = GuardTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        func s(_ gib: UInt64) -> [ProcessSample] {
            [ProcessSample(pid: 1, group: 1, footprint: gib * gb / 2, cpuNanos: 0), ProcessSample(pid: 2, group: 1, footprint: gib * gb / 2, cpuNanos: 0)]
        }
        XCTAssertTrue(t.ingest(s(2), now: t0).growers.isEmpty)
        XCTAssertTrue(t.ingest(s(4), now: t0 + 10).growers.isEmpty)
        let found = t.ingest(s(6), now: t0 + 20).growers
        XCTAssertEqual(found.map(\.group), [1])
        XCTAssertEqual(found.first?.grown, 4 * gb)
    }

    func testSlowGrowthOutsideWindowIsIgnored() {
        var t = GuardTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        for i in 0..<6 {
            let p = ProcessSample(pid: 1, group: 1, footprint: UInt64(i + 1) * gb, cpuNanos: 0) // +1 Go par minute
            XCTAssertTrue(t.ingest([p], now: t0 + Double(i) * 60).growers.isEmpty)
        }
    }

    func testCPUSaturation() {
        XCTAssertFalse(cpuSaturated(load1: 10, cores: 10))
        XCTAssertTrue(cpuSaturated(load1: 16, cores: 10))
        XCTAssertFalse(cpuSaturated(load1: 5, cores: 0))
    }

    func testGuardSettingsDefaultsAndTolerantDecoding() {
        let s = AppSettings.decode(Data("{\"autoClean\":true}".utf8))
        XCTAssertTrue(s.guardEnabled)
        XCTAssertTrue(s.guardCPU)
        XCTAssertFalse(s.guardAutoQuit) // jamais d'arrêt d'appli sans accord explicite
    }

    func testAutoCleanWaitsAfterAnAlertAndSkipsWhenUserIsAway() {
        var s = AppSettings(); s.autoClean = true; s.thresholdGB = 40
        let low = snapshot(used: 50)
        let now = Date()
        XCTAssertTrue(shouldAutoClean(settings: s, snapshot: low, lastRun: nil, now: now, busy: false, calmFor: .infinity, userIdle: 60))
        XCTAssertFalse(shouldAutoClean(settings: s, snapshot: low, lastRun: nil, now: now, busy: false, calmFor: 120, userIdle: 60))
        XCTAssertFalse(shouldAutoClean(settings: s, snapshot: low, lastRun: nil, now: now, busy: false, calmFor: .infinity, userIdle: 3 * 3600))
    }
}
