import XCTest
import PDFKit
@testable import MacDetectCore

final class ResetTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func machine(serial: String = "SYNTHETIC1234", model: String = "Mac14,3", chip: String = "Apple M2") -> MachineInfo {
        var machine = MachineInfo(); machine.serial = serial; machine.modelIdentifier = model; machine.chip = chip; machine.model = "Mac mini"
        return machine
    }
    func host() -> ResetHost {
        .init(machine: machine(), hardware: .appleSilicon, osMajor: 13, internalBoot: true, eraseAssistantAvailable: true,
              activation: .init("activation", "Activation", .security, status: .warning, summary: "enabled"),
              management: .init("management", "MDM", .security, status: .passed, summary: "not enrolled"), capturedAt: now)
    }
    func report() -> InspectionReport {
        var report = InspectionReport(mode: .quick); report.machine = machine(); report.finishedAt = now
        return report
    }
    func consent() -> ResetPreparation {
        var consent = ResetPreparation(); consent.authorizedAndBackedUp = true; consent.reportCopiedOffMac = true
        consent.accountsReviewed = true; consent.powerAndAccessoriesReady = true; consent.serialSuffix = "1234"
        return consent
    }
    func receipt(_ report: InspectionReport) -> ResetBackupReceipt { .init(reportID: report.id, machineSerial: report.machine.serial, createdAt: now) }
    func errors(_ host: ResetHost?, _ report: InspectionReport?, _ consent: ResetPreparation, _ receipt: ResetBackupReceipt?, busy: Bool = false, date: Date? = nil) -> [String] {
        ResetGate.blockers(host: host, report: report, preparation: consent, backup: receipt, busy: busy, now: date ?? now)
    }
    func testAppleSiliconDoesNotDependOnExecutableArchitecture() {
        let intel = machine(model: "Unknown", chip: "Intel Core i5")
        XCTAssertEqual(ResetHardware.identify(arm64: "1\n", machine: intel, bridge: nil), .appleSilicon)
        XCTAssertEqual(ResetHardware.identify(arm64: nil, machine: machine(), bridge: nil), .unknown)
    }
    func testT2RecognitionDoesNotGuessFromMissingData() throws {
        let intel = machine(model: "MacBookPro16,1", chip: "Intel Core i9")
        func bridge(_ name: String) throws -> Data { try JSONSerialization.data(withJSONObject: ["SPiBridgeDataType": [["ibridge_model_name": name]]]) }
        XCTAssertEqual(ResetHardware.identify(arm64: "0", machine: intel, bridge: try bridge("Apple T2 Security Chip")), .intelT2)
        XCTAssertEqual(ResetHardware.identify(arm64: "0", machine: intel, bridge: try bridge("Apple T1")), .intelUnconfirmed)
        XCTAssertEqual(ResetHardware.identify(arm64: "0", machine: intel, bridge: Data("{}".utf8)), .intelUnconfirmed)
        XCTAssertEqual(ResetHardware.identify(arm64: "0", machine: machine(model: "Macmini8,1", chip: "Intel Core i5"), bridge: nil), .intelT2)
        XCTAssertEqual(ResetHardware.identify(arm64: "0", machine: machine(model: "Macmini7,1", chip: "Intel Core i5"), bridge: nil), .intelUnconfirmed)
    }
    func testLaunchPlanOnlyReturnsFixedSystemAssistantAfterAllGates() throws {
        let report = report()
        let target = try ResetGate.launchTarget(host: host(), report: report, preparation: consent(), backup: receipt(report), busy: false, now: now)
        XCTAssertEqual(target.path, "/System/Library/CoreServices/Erase Assistant.app")
        // No test opens this URL or invokes an erase / reboot operation.
        XCTAssertThrowsError(try ResetGate.launchTarget(host: host(), report: report, preparation: ResetPreparation(), backup: receipt(report), busy: false, now: now))
    }
    func testEachAcknowledgementIsRequired() {
        let report = report()
        for key in [\ResetPreparation.authorizedAndBackedUp, \.reportCopiedOffMac, \.accountsReviewed, \.powerAndAccessoriesReady] {
            var preparation = consent(); preparation[keyPath: key] = false
            XCTAssertFalse(errors(host(), report, preparation, receipt(report)).isEmpty)
        }
        var preparation = consent(); preparation.serialSuffix = "4321"
        XCTAssertFalse(errors(host(), report, preparation, receipt(report)).isEmpty)
        preparation.serialSuffix = "1234 "
        XCTAssertFalse(errors(host(), report, preparation, receipt(report)).isEmpty)
    }
    func testCannotUseAnotherMacOrAnUnknownSerial() {
        let report = report(); var current = host(); current.machine.serial = "SYNTHETIC5678"
        XCTAssertFalse(errors(current, report, consent(), receipt(report)).isEmpty)
        current = host(); current.machine.modelIdentifier = "Mac15,13"
        XCTAssertFalse(errors(current, report, consent(), receipt(report)).isEmpty)
        current = host(); current.machine.serial = "无法读取"
        XCTAssertFalse(current.identityIsKnown)
        XCTAssertFalse(errors(current, report, consent(), receipt(report)).isEmpty)
    }
    func testBusyUnfinishedStaleAndFutureHostBlockLaunch() {
        var report = report(); let backup = receipt(report)
        XCTAssertFalse(errors(host(), report, consent(), backup, busy: true).isEmpty)
        XCTAssertFalse(errors(host(), report, consent(), backup, date: now.addingTimeInterval(301)).isEmpty)
        XCTAssertFalse(errors(host(), report, consent(), backup, date: now.addingTimeInterval(-1)).isEmpty)
        report.finishedAt = nil
        XCTAssertFalse(errors(host(), report, consent(), backup).isEmpty)
        XCTAssertFalse(errors(nil, report, consent(), backup).isEmpty)
        XCTAssertFalse(errors(host(), nil, consent(), backup).isEmpty)
    }
    func testUnsupportedHostAndManagedMacBlockLaunch() {
        let report = report()
        var current = host(); current.hardware = .intelUnconfirmed
        XCTAssertFalse(errors(current, report, consent(), receipt(report)).isEmpty)
        current = host(); current.osMajor = 11
        XCTAssertFalse(errors(current, report, consent(), receipt(report)).isEmpty)
        current = host(); current.internalBoot = false
        XCTAssertFalse(errors(current, report, consent(), receipt(report)).isEmpty)
        current = host(); current.internalBoot = nil
        XCTAssertFalse(errors(current, report, consent(), receipt(report)).isEmpty)
        current = host(); current.eraseAssistantAvailable = false
        XCTAssertFalse(errors(current, report, consent(), receipt(report)).isEmpty)
        current = host(); current.management.status = .warning
        XCTAssertFalse(errors(current, report, consent(), receipt(report)).isEmpty)
    }
    func testAReportBackupFieldCannotAuthorizeLaunch() {
        var report = report(); report.resetRecord = ResetRecord(); report.resetRecord?.backupExportedAt = now
        XCTAssertFalse(errors(host(), report, consent(), nil).isEmpty)
        XCTAssertFalse(errors(host(), report, consent(), .init(reportID: UUID(), machineSerial: report.machine.serial, createdAt: now)).isEmpty)
        XCTAssertFalse(errors(host(), report, consent(), .init(reportID: report.id, machineSerial: "OTHER12345678", createdAt: now)).isEmpty)
        XCTAssertFalse(errors(host(), report, consent(), .init(reportID: report.id, machineSerial: report.machine.serial, createdAt: now.addingTimeInterval(-86401))).isEmpty)
    }
    func testOpeningAssistantNeverClaimsEraseSuccess() {
        var record = ResetRecord(); record.assistantRequestedAt = now; record.assistantOpenedAt = now
        XCTAssertEqual(record.unresolvedCount, 3)
        XCTAssertTrue(record.summary.contains("未自动验证"))
        record.assistantError = "synthetic launch error"
        XCTAssertTrue(record.lines.contains { $0.contains("synthetic launch error") })
        for i in record.postChecks.indices { record.postChecks[i].state = .passed }
        XCTAssertEqual(record.unresolvedCount, 3)
        for i in record.postChecks.indices { record.postChecks[i].note = "人工观察记录" }
        XCTAssertEqual(record.unresolvedCount, 0)
        XCTAssertTrue(record.summary.contains("不构成自动抹除证明"))
    }
    func testPostHandoffIssueAffectsVerdictWithoutRewritingAutomaticResults() {
        var report = report()
        for i in report.checks.indices { report.checks[i].status = .passed }
        for i in report.manual.indices { report.manual[i].state = .passed }
        let original = report.checks
        report.resetRecord = ResetRecord()
        XCTAssertTrue(report.verdict.contains("未完成"))
        report.resetRecord?.postChecks[0].state = .issue
        XCTAssertTrue(report.hasIssue); XCTAssertTrue(report.verdict.contains("暂停收购"))
        XCTAssertEqual(report.checks, original)
    }
    func testGuidesSeparateDataPreservingAndDestructiveOperations() {
        let retain = ResetGuide.make(goal: .reinstall, hardware: .appleSilicon)
        XCTAssertTrue(retain.detail.contains("保留应用与个人数据"))
        XCTAssertTrue(retain.steps.contains { $0.contains("长按电源") })
        let intel = ResetGuide.make(goal: .recoveryErase, hardware: .intelUnconfirmed)
        XCTAssertTrue(intel.steps.contains { $0.contains("Command-R") })
        let dfu = ResetGuide.make(goal: .dfu, hardware: .appleSilicon)
        XCTAssertTrue(dfu.detail.contains("辅助机"))
        XCTAssertTrue(dfu.steps.contains { $0.contains("Revive") && $0.contains("Restore") })
        for goal in ResetGoal.allCases { XCTAssertTrue(ResetGuide.make(goal: goal, hardware: .unknown).links.allSatisfy { $0.url.host == "support.apple.com" && $0.url.scheme == "https" }) }
    }
    func testPackageRoundTripPreservesReportsAndDoesNotRestoreAuthorization() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var report = report(); report.resetRecord = ResetRecord(); report.resetRecord?.backupExportedAt = now
        report.resetRecord?.postChecks[0].note = "<script>synthetic</script> EndOfHandoffObservation"
        let directory = try HandoffPackage.export(report, host: host(), into: root)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), Set(["验机报告.json", "验机报告.html", "验机报告.pdf", "交机操作单.txt"]))
        let imported = try HandoffPackage.read(directory.appendingPathComponent("验机报告.json"))
        XCTAssertNotEqual(imported.id, report.id); XCTAssertEqual(imported.importedFromReportID, report.id)
        XCTAssertEqual(imported.checks, report.checks); XCTAssertEqual(imported.resetRecord, report.resetRecord)
        XCTAssertFalse(errors(host(), imported, ResetPreparation(), nil).isEmpty)
        let html = try String(contentsOf: directory.appendingPathComponent("验机报告.html"))
        XCTAssertTrue(html.contains("&lt;script&gt;")); XCTAssertFalse(html.contains("<script>"))
        let pdf = try XCTUnwrap(PDFDocument(url: directory.appendingPathComponent("验机报告.pdf")))
        XCTAssertTrue(pdf.string?.contains("EndOfHandoffObservation") == true)
        XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("交机操作单.txt")).contains("SYNTHETIC1234"))
    }
    func testMalformedFutureAndOversizedImportsAreRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{}".utf8).write(to: url); XCTAssertThrowsError(try HandoffPackage.read(url))
        var report = report(); report.schemaVersion = 99
        try ReportExporter.json(report).write(to: url); XCTAssertThrowsError(try HandoffPackage.read(url))
        report.schemaVersion = 3; report.checks.append(report.checks[0])
        try ReportExporter.json(report).write(to: url); XCTAssertThrowsError(try HandoffPackage.read(url))
        try Data(repeating: 65, count: 4 * 1024 * 1024 + 1).write(to: url); XCTAssertThrowsError(try HandoffPackage.read(url))
    }
    func testOlderReportsDecodeWithoutResetState() throws {
        var report = report(); report.schemaVersion = 2
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ReportExporter.json(report).write(to: url)
        let imported = try HandoffPackage.read(url)
        XCTAssertNil(imported.resetRecord)
        XCTAssertEqual(imported.softwareVersion, report.softwareVersion)
    }
    func testReadOnlyHostProbeDoesNotLaunchAnAssistant() throws {
        guard let executable = ProcessInfo.processInfo.environment["MACDETECT_TEST_APP"] else { throw XCTSkip("Native readiness probe requires MACDETECT_TEST_APP") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ProcessRunner.run(executable, ["--reset-readiness-report", url.path], timeout: 110, cancellation: CancellationToken())
        XCTAssertEqual(result.exitCode, 0); XCTAssertNil(result.interruption)
        let host = try JSONDecoder().decode(ResetHost.self, from: Data(contentsOf: url))
        XCTAssertTrue(host.identityIsKnown)
        XCTAssertFalse(ResetGate.blockers(host: host, report: nil, preparation: ResetPreparation(), backup: nil, busy: false).isEmpty)
        XCTAssertTrue(result.text.contains("未启动抹除"))
    }
}
