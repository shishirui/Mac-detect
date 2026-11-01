import XCTest
@testable import MacDetectCore

final class NVMeTests: XCTestCase {
    func fixture() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[1] = 0x3e; bytes[2] = 1 // 318 K
        bytes[3] = 100; bytes[4] = 10; bytes[5] = 2
        bytes[48] = 1
        return bytes
    }
    func testNVMeUnitsAndKelvin() throws {
        let health = try SSDHealth.parse(Data(fixture()), disk: "disk7")
        XCTAssertEqual(health.disk, "disk7")
        XCTAssertEqual(health.writtenBytesUpperBound, "512000")
        XCTAssertEqual(health.temperatureCelsius!, 44.85, accuracy: 0.001)
        XCTAssertEqual(health.percentageUsed, 2)
        XCTAssertEqual(health.check.status, .passed)
    }
    func testFull128BitCounterWithoutPrecisionLoss() throws {
        var bytes = fixture()
        for i in 48..<64 { bytes[i] = 255 }
        let health = try SSDHealth.parse(Data(bytes), disk: "disk0")
        XCTAssertEqual(health.dataUnitsWritten, "340282366920938463463374607431768211455")
        XCTAssertEqual(health.writtenBytesUpperBound, "174224571863520493293247799005065324264960000")
        XCTAssertEqual(WideCounter.decimal([0, 0, 1][...]), "65536")
    }
    func testMissingAndMalformedDataNeverPass() throws {
        XCTAssertThrowsError(try SSDHealth.parse(Data(repeating: 0, count: 512), disk: "disk0"))
        XCTAssertThrowsError(try SSDHealth.parse(Data(fixture().prefix(511)), disk: "disk0"))
        var bytes = fixture(); bytes[3] = 101
        XCTAssertThrowsError(try SSDHealth.parse(Data(bytes), disk: "disk0"))
        bytes = fixture(); bytes[48] = 0
        let missing = try SSDHealth.parse(Data(bytes), disk: "disk0")
        XCTAssertNil(missing.writtenBytesUpperBound)
        XCTAssertEqual(missing.writtenText, "未上报")
        XCTAssertEqual(missing.check.status, .unavailable)
        bytes[1] = 0; bytes[2] = 0
        XCTAssertNil(try SSDHealth.parse(Data(bytes), disk: "disk0").temperatureCelsius)
    }
    func testWearSpareAndCriticalWarningSemantics() throws {
        var bytes = fixture(); bytes[5] = 100
        XCTAssertEqual(try SSDHealth.parse(Data(bytes), disk: "disk0").check.status, .warning)
        bytes[5] = 255
        XCTAssertEqual(try SSDHealth.parse(Data(bytes), disk: "disk0").enduranceText, ">254%")
        bytes = fixture(); bytes[3] = 9
        XCTAssertEqual(try SSDHealth.parse(Data(bytes), disk: "disk0").check.status, .warning)
        bytes = fixture(); bytes[0] = 8
        let check = try SSDHealth.parse(Data(bytes), disk: "disk0").check
        XCTAssertEqual(check.status, .warning)
        XCTAssertTrue(check.evidence.contains("介质进入只读状态"))
    }
    func testHistoricalCountsAreNotCurrentHardwareFaults() throws {
        var bytes = fixture(); bytes[112] = 200; bytes[128] = 200; bytes[144] = 200; bytes[176] = 200
        XCTAssertEqual(try SSDHealth.parse(Data(bytes), disk: "disk0").check.status, .passed)
        bytes[160] = 1
        XCTAssertEqual(try SSDHealth.parse(Data(bytes), disk: "disk0").check.status, .warning)
    }
}

final class BootDiskTests: XCTestCase {
    func plist(_ data: [String: Any]) throws -> Data { try PropertyListSerialization.data(fromPropertyList: data, format: .binary, options: 0) }
    func testMapsActualBootStoreInsteadOfAssumingDiskZero() throws {
        XCTAssertEqual(try BootDiskResolver.physicalStore(plist(["Internal": true, "APFSPhysicalStores": [["APFSPhysicalStore": "disk7s2"]]])), "disk7s2")
        XCTAssertEqual(try BootDiskResolver.wholeDisk(plist(["Internal": true, "SolidState": true, "ParentWholeDisk": "disk7"])), "disk7")
    }
    func testRejectsExternalMultipleAndVirtualStores() throws {
        XCTAssertThrowsError(try BootDiskResolver.physicalStore(plist(["Internal": false, "ParentWholeDisk": "disk0"])))
        XCTAssertThrowsError(try BootDiskResolver.physicalStore(plist(["Internal": true, "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"], ["APFSPhysicalStore": "disk1s2"]]])))
        XCTAssertThrowsError(try BootDiskResolver.physicalStore(plist(["Internal": true, "APFSPhysicalStores": []])))
        XCTAssertThrowsError(try BootDiskResolver.wholeDisk(plist(["Internal": true, "SolidState": true, "VirtualOrPhysical": "Virtual", "ParentWholeDisk": "disk3"])))
        XCTAssertThrowsError(try BootDiskResolver.wholeDisk(plist(["Internal": true, "SolidState": true, "ParentWholeDisk": "disk0s2"])))
        XCTAssertFalse(BootDiskResolver.validDevice("disk0; rm -rf /"))
    }
}

final class SensorTests: XCTestCase {
    func testSMCEndiannessAndSignedFixedPoint() {
        XCTAssertEqual(SMCNumber.decode(type: "flt ", bytes: [0, 0, 0x48, 0x42]), 50)
        XCTAssertEqual(SMCNumber.decode(type: "sp78", bytes: [0xff, 0x80]), -0.5)
        XCTAssertEqual(SMCNumber.decode(type: "sp78", bytes: [0x32, 0x80]), 50.5)
        XCTAssertEqual(SMCNumber.decode(type: "fpe2", bytes: [0x1f, 0x40]), 2000)
        XCTAssertEqual(SMCNumber.decode(type: "ui32", bytes: [0, 0, 7, 0x37]), 1847)
        XCTAssertEqual(SMCNumber.name(SMCNumber.key("F0Ac")), "F0Ac")
    }
    func testSMCRejectsNaNUnknownAndTruncatedValues() {
        XCTAssertNil(SMCNumber.decode(type: "flt ", bytes: [0, 0, 0xc0, 0x7f]))
        XCTAssertNil(SMCNumber.decode(type: "flt ", bytes: [0, 0, 0x80, 0x7f]))
        XCTAssertNil(SMCNumber.decode(type: "sp78", bytes: [0]))
        XCTAssertNil(SMCNumber.decode(type: "ui16", bytes: [0, 1, 2]))
        XCTAssertNil(SMCNumber.decode(type: "xyz ", bytes: [1]))
    }
    func testFanlessMissingAndStoppedAreDistinct() {
        var session = SensorSession(); session.add(SensorSnapshot())
        var mini = MachineInfo(); mini.modelIdentifier = "Mac14,3"
        XCTAssertEqual(session.fanCheck(machine: mini).status, .unavailable)
        var air = MachineInfo(); air.modelIdentifier = "Mac15,12"
        XCTAssertEqual(session.fanCheck(machine: air).status, .notApplicable)
        air.modelIdentifier = "MacBookAir9,1" // Intel Air has a fan
        XCTAssertEqual(session.fanCheck(machine: air).status, .unavailable)
        var stopped = SensorSnapshot(); stopped.fanCount = 1; stopped.fans = [.init(key: "F0Ac", value: 0)]
        session = SensorSession(); session.add(stopped)
        XCTAssertEqual(session.fanCheck(machine: mini).status, .passed)
        XCTAssertTrue(session.fanCheck(machine: mini).evidence.contains { $0.contains("0 RPM") })
        var absent = SensorSnapshot(); absent.fanCount = 0
        session = SensorSession(); session.add(absent)
        XCTAssertEqual(session.fanCheck(machine: mini).status, .unavailable)
    }
    func testRangesMissingSamplesAndStaleOrdering() {
        var session = SensorSession()
        var sample = SensorSnapshot(); sample.temperatures = [.init(key: "Tp01", value: 50)]; sample.fanCount = 1; sample.fans = [.init(key: "F0Ac", value: 1000)]
        session.add(sample); session.add(sample)
        XCTAssertEqual(session.sampleCount, 1)
        sample.sampledAt.addTimeInterval(2); sample.temperatures[0].value = 70; sample.fans[0].value = 3000; session.add(sample)
        XCTAssertEqual(session.temperatures[0].minimum, 50)
        XCTAssertEqual(session.temperatures[0].maximum, 70)
        XCTAssertEqual(session.fans[0].maximum, 3000)
        XCTAssertEqual(session.temperatureCheck().status, .passed)
        sample.sampledAt.addTimeInterval(2); sample.temperatures = []; sample.fans = []; session.add(sample)
        XCTAssertEqual(session.temperatureCheck().status, .warning)
        XCTAssertEqual(session.fanCheck(machine: MachineInfo()).status, .warning)
        XCTAssertEqual(session.latest?.temperatures.count, 0)
        XCTAssertEqual(session.temperatures[0].samples, 2)
    }
    func testInterruptedAndSeriousThermalStateRequireReview() {
        var session = SensorSession(); var sample = SensorSnapshot(); sample.temperatures = [.init(key: "Tp01", value: 70)]; sample.thermalState = 2
        session.add(sample)
        XCTAssertEqual(session.temperatureCheck().status, .warning)
        session = SensorSession(); sample.thermalState = 0; session.add(sample); session.interrupted = true
        XCTAssertEqual(session.temperatureCheck().status, .warning)
    }
    func testOldReportsRemainReadableAndNAIsResolvedNotPassed() throws {
        var report = InspectionReport(mode: .quick)
        for i in report.checks.indices { report.checks[i].status = .passed }
        for i in report.manual.indices { report.manual[i].state = .passed }
        report.checks[0].status = .notApplicable
        XCTAssertEqual(report.unresolvedCount, 0)
        XCTAssertEqual(report.passedCount, report.checks.count - 1)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        json.removeValue(forKey: "sensors"); json.removeValue(forKey: "ssdHealth"); json["schemaVersion"] = 1
        let old = try JSONDecoder().decode(InspectionReport.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.sensors); XCTAssertNil(old.ssdHealth)
    }
    func testMonitorCollectsAndStopsHelper() throws {
        guard let path = ProcessInfo.processInfo.environment["MACDETECT_TEST_APP"] else { throw XCTSkip("Set MACDETECT_TEST_APP for native sensor helper integration") }
        let monitor = try SensorMonitor(executable: path)
        defer { monitor.stop() }
        let deadline = Date().addingTimeInterval(12)
        var sample: SensorSnapshot?
        while Date() < deadline && sample == nil { sample = monitor.poll(); Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertNotNil(sample)
        XCTAssertFalse(monitor.failed)
        let start = Date(); monitor.stop(); XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }
    func testCancelledStandardScanKeepsSampleRanges() throws {
        guard let path = ProcessInfo.processInfo.environment["MACDETECT_TEST_APP"] else { throw XCTSkip("Native integration requires MACDETECT_TEST_APP") }
        let token = CancellationToken()
        var started = false
        let report = Scanner(mode: .standard, executable: path, token: token) { event in
            if case .result(let check) = event, check.id == "cpu", check.status == .running, !started {
                started = true
                DispatchQueue.global().asyncAfter(deadline: .now() + 6) { token.cancel() }
            }
        }.run()
        XCTAssertTrue(started)
        XCTAssertNotNil(report.finishedAt)
        // In a safety stop, later workers may complete before cancellation; retain
        // the actual result instead of insisting that a hot host run a full load.
        XCTAssertGreaterThan(report.sensors?.sampleCount ?? 0, 1)
        if report.wasCancelled { XCTAssertEqual(report.sensors?.interrupted, true) }
        XCTAssertFalse(report.checks.contains { $0.status == .running || $0.status == .pending })
    }
    func testRecoveryMarksContinuousSensorHistoryIncomplete() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try ReportStorage(directory: directory)
        var report = InspectionReport(mode: .standard); var session = SensorSession()
        var sample = SensorSnapshot(); sample.temperatures = [.init(key: "Tp01", value: 50)]; session.add(sample)
        report.sensors = session
        try storage.save(report)
        let restored = try XCTUnwrap(storage.all().first)
        XCTAssertEqual(restored.sensors?.interrupted, true)
        XCTAssertEqual(restored.checks.first { $0.id == "temperature" }?.status, .warning)
    }
    func testExitedMonitorIsNotReportedAsHealthy() throws {
        let monitor = try SensorMonitor(executable: "/usr/bin/false")
        defer { monitor.stop() }
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertNil(monitor.poll()); XCTAssertTrue(monitor.failed)
    }
    func testStalledMonitorIsTerminatedAtDeadline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("stalled-helper")
        try Data("#!/bin/sh\nexec /bin/sleep 60\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let monitor = try SensorMonitor(executable: helper.path)
        defer { monitor.stop() }
        let start = Date()
        while !monitor.failed && Date().timeIntervalSince(start) < 18 { XCTAssertNil(monitor.poll()); Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertTrue(monitor.failed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 18)
    }
    func testProcessTicksWhileWorkerRuns() throws {
        var ticks = 0
        let result = try ProcessRunner.run("/bin/sleep", ["0.3"], cancellation: CancellationToken(), onTick: { ticks += 1 })
        XCTAssertEqual(result.exitCode, 0); XCTAssertGreaterThan(ticks, 1)
    }
}
