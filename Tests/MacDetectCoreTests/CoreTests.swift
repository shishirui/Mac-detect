import XCTest
@testable import MacDetectCore

final class ParserTests: XCTestCase {
    func hardware(_ status: String?) throws -> Data {
        var row: [String: Any] = ["machine_model": "Mac14,3", "machine_name": "Mac mini", "chip_type": "Apple M2", "physical_memory": "16 GB", "serial_number": "TEST-ONLY", "number_processors": "proc 8:0:4:4"]
        if let status { row["activation_lock_status"] = status }
        return try JSONSerialization.data(withJSONObject: ["SPHardwareDataType": [row]])
    }
    func testMissingActivationNeverPasses() throws {
        let (machine, check) = try SystemParsers.hardware(hardware(nil))
        XCTAssertEqual(machine.chip, "Apple M2")
        XCTAssertEqual(machine.cores, "8 核")
        XCTAssertEqual(check.status, .unavailable)
        XCTAssertEqual(try SystemParsers.hardware(hardware("future_unknown_state")).1.status, .unavailable)
    }
    func testExplicitActivationStates() throws {
        XCTAssertEqual(try SystemParsers.hardware(hardware("activation_lock_enabled")).1.status, .warning)
        XCTAssertEqual(try SystemParsers.hardware(hardware("activation_lock_disabled")).1.status, .passed)
        XCTAssertThrowsError(try SystemParsers.hardware(Data("{}".utf8)))
    }
    func testStorageIdentityAndHealth() throws {
        func parse(_ object: [String: Any]) throws -> CheckStatus {
            let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
            return try SystemParsers.storage(data).0.status
        }
        XCTAssertEqual(try parse(["SMARTStatus": "Verified", "Internal": true]), .passed)
        XCTAssertEqual(try parse(["SMARTStatus": "Verified", "Internal": false]), .unavailable)
        XCTAssertEqual(try parse(["SMARTStatus": "Verified"]), .unavailable)
        XCTAssertEqual(try parse(["Internal": true]), .unavailable)
        XCTAssertEqual(try parse(["SMARTStatus": "Failing", "Internal": true]), .failed)
        XCTAssertEqual(try parse(["SMARTStatus": "Not Supported", "Internal": true]), .unavailable)
    }
    func testManagementRequiresBothExplicitNegativesAndSuccess() {
        let negative = "Enrolled via DEP: No\nMDM enrollment: No\n"
        XCTAssertEqual(SystemParsers.management(negative, exitCode: 0).status, .passed)
        XCTAssertEqual(SystemParsers.management(negative, exitCode: 1).status, .unavailable)
        XCTAssertEqual(SystemParsers.management("MDM enrollment: No", exitCode: 0).status, .unavailable)
        XCTAssertEqual(SystemParsers.management("Enrolled via DEP: Yes\nMDM enrollment: No", exitCode: 0).status, .warning)
        XCTAssertEqual(SystemParsers.management("MDM enrollment: Yes (User Approved)", exitCode: 0).status, .warning)
        XCTAssertEqual(SystemParsers.management("permission denied", exitCode: 1).status, .unavailable)
    }
}

final class ReportTests: XCTestCase {
    func testIncompleteNeverGetsCleanVerdict() {
        var report = InspectionReport(mode: .quick)
        for index in report.checks.indices { report.checks[index].status = .passed }
        XCTAssertTrue(report.verdict.contains("未完成"))
        for index in report.manual.indices { report.manual[index].state = .passed }
        XCTAssertEqual(report.verdict, "本次验机未发现异常")
        report.checks[0].status = .unavailable
        XCTAssertTrue(report.verdict.contains("未完成"))
        report.checks[0].status = .warning
        XCTAssertTrue(report.verdict.contains("复核"))
        report.checks[0].status = .failed
        XCTAssertTrue(report.verdict.contains("暂停收购"))
    }
    func testManualExemptionsNeedExplanation() {
        var item = ManualCheck.defaults[0]
        item.state = .notApplicable
        XCTAssertFalse(item.isResolved)
        item.note = "  \n"
        XCTAssertFalse(item.isResolved)
        item.note = "机型没有该接口"
        XCTAssertTrue(item.isResolved)
        item.state = .issue; item.note = ""
        XCTAssertFalse(item.isResolved)
    }
    func testHTMLInjectionIsEscaped() {
        var report = InspectionReport(mode: .quick)
        report.notes = "<script>alert('x')</script> & \"quote\""
        let html = ReportExporter.html(report)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("&amp;"))
    }
    func testPersistenceAndInterruptedRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try ReportStorage(directory: directory)
        var report = InspectionReport(mode: .standard)
        report.checks[0].status = .passed; report.checks[1].status = .running
        report.notes = "中文备注"
        try storage.save(report)
        let loaded = try XCTUnwrap(storage.all().first)
        XCTAssertEqual(loaded.notes, "中文备注")
        XCTAssertEqual(loaded.checks[0].status, .passed)
        XCTAssertEqual(loaded.checks[1].status, .interrupted)
        XCTAssertTrue(loaded.wasCancelled)
        report.finishedAt = Date()
        try storage.save(report)
        XCTAssertEqual(try storage.all().count, 1)
        let encoded = try ReportExporter.json(report)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(InspectionReport.self, from: encoded).id, report.id)
    }
    func testCancellationFinalizesAllChecks() {
        let token = CancellationToken(); token.cancel()
        let report = Scanner(mode: .standard, executable: "/invalid", token: token, emit: { _ in }).run()
        XCTAssertTrue(report.wasCancelled)
        XCTAssertNotNil(report.finishedAt)
        XCTAssertTrue(report.checks.allSatisfy { $0.status == .interrupted })
    }
}

final class ProcessTests: XCTestCase {
    func testTimeoutKillsChildPromptly() throws {
        let start = ProcessInfo.processInfo.systemUptime
        let output = try ProcessRunner.run("/bin/sleep", ["10"], timeout: 0.1, cancellation: CancellationToken())
        XCTAssertTrue(output.interruption?.contains("超时") == true)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }
    func testCancellationDuringProcess() throws {
        let token = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { token.cancel() }
        let output = try ProcessRunner.run("/bin/sleep", ["10"], timeout: 20, cancellation: token)
        XCTAssertTrue(output.interruption?.contains("停止") == true)
    }
    func testNoShellExpansion() throws {
        let output = try ProcessRunner.run("/bin/echo", ["$(exit 2)", ";", "你好"], cancellation: CancellationToken())
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.text, "$(exit 2) ; 你好\n")
    }
}

final class WorkerTests: XCTestCase {
    func testCPUReferenceVectorsAndExecution() {
        XCTAssertEqual(Workers.cpuVector(), 0xd1b04aa9e63ddb2b)
        XCTAssertEqual(Workers.cpuVector(seed: 0x123456789abcdef1), 0xe715d2e7888a1758)
        XCTAssertEqual(Workers.cpu(seconds: 0.05, parallelism: 1).status, .passed)
    }
    func testSmallMemoryReadback() { XCTAssertEqual(Workers.memory(seconds: 0.05, mebibytes: 1).status, .passed) }
    func testDiskReadbackPreservesOtherFilesAndCleansUp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("do-not-touch.txt")
        try Data("preserve".utf8).write(to: sentinel)
        let result = Workers.disk(directory: directory, mebibytes: 2)
        XCTAssertTrue([CheckStatus.passed, .warning].contains(result.status), result.summary)
        XCTAssertTrue(result.summary.contains("校验通过"), result.summary)
        XCTAssertEqual(try String(contentsOf: sentinel), "preserve")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["do-not-touch.txt"])
    }
    func testDiskRejectsMissingDirectory() {
        let result = Workers.disk(directory: URL(fileURLWithPath: "/nonexistent-MacDetect-\(UUID().uuidString)"), mebibytes: 1)
        XCTAssertNotEqual(result.status, .passed)
    }
}

import PDFKit
final class PDFTests: XCTestCase {
    func testSectionTitlesStayWithBody() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacDetect-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var report = InspectionReport(mode: .quick)
        report.machine.serial = "SYNTHETIC-TEST"
        for index in report.checks.indices {
            report.checks[index].summary = "BODYMARKER\(index)END"
            report.checks[index].evidence = [String(repeating: "这是用于分页验证的说明。", count: 10)]
        }
        try PDFExporter.write(report, to: url)
        let document = try XCTUnwrap(PDFDocument(url: url))
        for (index, check) in report.checks.enumerated() {
            let page = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.first { $0.contains(check.title + "  ·") || $0.contains(check.title + " ·") }
            XCTAssertNotNil(page, check.title)
            XCTAssertTrue(page?.filter { !$0.isWhitespace }.contains("BODYMARKER\(index)END") == true, "Heading separated from body: \(check.title)")
        }
    }
    func testLongOperatorNotesAreNotTruncated() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacDetect-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var report = InspectionReport(mode: .quick)
        report.notes = String(repeating: "长备注分页验证内容。", count: 800) + "EndOfOperatorNote0123"
        try PDFExporter.write(report, to: url)
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(document.pageCount > 4)
        XCTAssertTrue(document.string?.filter { !$0.isWhitespace }.contains("EndOfOperatorNote0123") == true)
        XCTAssertTrue(document.string?.contains("检测边界") == true)
    }
}
