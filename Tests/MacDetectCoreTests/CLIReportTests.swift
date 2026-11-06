import XCTest
import PDFKit
@testable import MacDetectCore

final class CLIReportTests: XCTestCase {
    private func executable() throws -> String {
        try XCTUnwrap(ProcessInfo.processInfo.environment["MACDETECT_TEST_APP"].flatMap {
            FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
        }, "Set MACDETECT_TEST_APP to the built executable to run CLI integration tests")
    }

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["MACDETECT_TEST_APP"] == nil,
                      "Requires MACDETECT_TEST_APP, like the native hardware integration tests")
    }

    func testInvalidReportArgumentsFailWithoutStartingGUIOrScan() throws {
        let app = try executable()
        for arguments in [["--standard-report"], ["--quick-report"], ["--standard-report", ""],
                          ["--standard-report", "--unknown"],
                          ["--quick-report", "/tmp/unused.json", "--standard-report", "/tmp/unused.json"]] {
            let output = try ProcessRunner.run(app, arguments, timeout: 5, cancellation: CancellationToken())
            XCTAssertNil(output.interruption)
            XCTAssertEqual(output.exitCode, 2)
            XCTAssertTrue(output.data.isEmpty)
        }
    }

    func testStandardReportExportsAllFormatsAndRunsStandardWorkers() throws {
        try checkReport(mode: .standard)
    }

    func testQuickReportStillExportsAllFormatsWithoutWorkers() throws {
        try checkReport(mode: .quick)
    }

    private func checkReport(mode: InspectionMode) throws {
        let app = try executable()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacDetect CLI \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = directory.appendingPathComponent("workers")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
        let helper = directory.appendingPathComponent("helper")
        // Override argv[0] only in this test. Real probes and exporters run, while
        // worker fixtures record the requested settings without a 15-minute load.
        try Data("""
        #!/bin/sh
        if [ "$1" = "--worker" ]; then
            printf '%s\\n' "$@" > "$MACDETECT_CLI_WORKER_LOG/$2"
            printf '%s\\n' '{"status":"warning","summary":"CLI workload fixture","evidence":[]}'
        else
            exec "$MACDETECT_TEST_APP" "$@"
        fi
        """.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let destination = directory.appendingPathComponent("验机报告.json")
        let output = try ProcessRunner.run("/usr/bin/env", ["MACDETECT_CLI_WORKER_LOG=\(logs.path)",
            "/bin/bash", "-c", "exec -a \"$1\" \"$2\" \"$3\" \"$4\"", "cli-test",
            helper.path, app, "--\(mode.rawValue)-report", destination.path],
            timeout: 180, cancellation: CancellationToken())
        XCTAssertNil(output.interruption)
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertTrue(output.text.contains(mode.title + "完成"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(InspectionReport.self, from: Data(contentsOf: destination))
        XCTAssertEqual(report.mode, mode)
        XCTAssertNotNil(report.finishedAt)
        XCTAssertFalse(report.checks.contains { $0.status == .running || $0.status == .pending })
        XCTAssertTrue(report.manual.allSatisfy { $0.state == .unverified })
        let html = try String(contentsOf: destination.deletingPathExtension().appendingPathExtension("html"))
        XCTAssertTrue(html.contains(mode.title))
        let pdf = try XCTUnwrap(PDFDocument(url: destination.deletingPathExtension().appendingPathExtension("pdf")))
        XCTAssertGreaterThan(pdf.pageCount, 0)
        XCTAssertTrue(pdf.string?.contains(mode.title) == true)
        if mode == .standard {
            for id in ["cpu", "memory", "gpu", "disk"] {
                let arguments = try String(contentsOf: logs.appendingPathComponent(id)).components(separatedBy: "\n")
                XCTAssertEqual(Array(arguments.prefix(4)), ["--worker", id, "--seconds", id == "disk" ? "180.0" : "300.0"])
                if id == "memory" { XCTAssertEqual(Array(arguments[4..<6]), ["--mib", "256"]) }
                if id == "disk" {
                    XCTAssertEqual(arguments[4], "--directory")
                    XCTAssertFalse(FileManager.default.fileExists(atPath: arguments[5]))
                    XCTAssertEqual(Array(arguments[6..<8]), ["--mib", "512"])
                }
                XCTAssertEqual(report.checks.first { $0.id == id }?.summary, "CLI workload fixture")
            }
            XCTAssertTrue(html.contains("CLI workload fixture"))
            XCTAssertTrue(pdf.string?.contains("CLI workload fixture") == true)
        } else {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: logs.path).isEmpty)
            XCTAssertTrue(report.checks.filter { ["cpu", "memory", "gpu", "disk"].contains($0.id) }.allSatisfy { $0.status == .skipped })
        }
    }
}
