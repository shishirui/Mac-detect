import SwiftUI
import AppKit
import MacDetectCore
import CoreText
import UniformTypeIdentifiers

@MainActor final class AppStore: ObservableObject {
    @Published var report: InspectionReport?
    @Published var history: [InspectionReport] = []
    @Published var mode: InspectionMode = .quick
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var selectedPage: AppPage = .overview
    @Published var currentCheckStarted: Date?
    @Published var showSerial = false
    private var cancellation: CancellationToken?
    private var storage: ReportStorage?
    var afterStopped: (() -> Void)?
    init() {
        do { storage = try ReportStorage(); history = try storage!.all() }
        catch { errorMessage = "无法打开本地报告目录：\(error.localizedDescription)" }
    }
    var checks: [CheckResult] { report?.checks ?? CheckResult.initial }
    var machine: MachineInfo { report?.machine ?? MachineInfo() }
    var currentCheck: CheckResult? { checks.first { $0.status == .running } }
    var finishedCount: Int { checks.filter { $0.status.isFinished }.count }
    var manualDone: Int { report?.manual.filter { $0.isResolved }.count ?? 0 }
    var serialDisplay: String {
        let serial = machine.serial
        return showSerial || serial.count < 6 ? serial : "•••• \(serial.suffix(4))"
    }
    func start() {
        guard !isRunning else { return }
        let token = CancellationToken(); cancellation = token
        let fresh = InspectionReport(mode: mode)
        report = fresh; isRunning = true; selectedPage = .overview; persist()
        let path = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        Task { [self] in
            let final = await Task.detached(priority: .userInitiated) { [weak self] in
                Scanner(mode: fresh.mode, executable: path, token: token, report: fresh) { event in
                    Task { @MainActor [weak self] in
                        guard let self, self.isRunning, self.report?.id == fresh.id else { return }
                        switch event {
                        case .machine(let machine): self.report?.machine = machine
                        case .result(let result):
                            if let index = self.report?.checks.firstIndex(where: { $0.id == result.id }) { self.report?.checks[index] = result }
                            if result.status == .running { self.currentCheckStarted = Date() }
                        }
                        self.persist()
                    }
                }.run()
            }.value
            // Preserve operator notes entered while automatic checks ran.
            var merged = final
            if let live = report, live.id == final.id {
                merged.manual = live.manual; merged.notes = live.notes; merged.assetTag = live.assetTag
            }
            report = merged; isRunning = false; currentCheckStarted = nil; cancellation = nil
            persist(); reloadHistory()
            afterStopped?(); afterStopped = nil
        }
    }
    func stop() { cancellation?.cancel() }
    func setManual(_ id: String, state: ManualState? = nil, note: String? = nil) {
        guard let index = report?.manual.firstIndex(where: { $0.id == id }) else { return }
        if let state { report?.manual[index].state = state }
        if let note { report?.manual[index].note = String(note.prefix(4000)) }
        report?.manual[index].updatedAt = Date(); persist()
    }
    func setNotes(_ value: String) { report?.notes = String(value.prefix(16000)); persist() }
    func setAssetTag(_ value: String) { report?.assetTag = String(value.prefix(200)); persist() }
    func load(_ item: InspectionReport) {
        guard !isRunning else { return }
        report = item; mode = item.mode; selectedPage = .report
    }
    func persist() {
        guard let report, let storage else { return }
        do { try storage.save(report) }
        catch { errorMessage = "本地报告保存失败，请导出备份：\(error.localizedDescription)" }
    }
    func reloadHistory() { do { history = try storage?.all() ?? [] } catch { errorMessage = error.localizedDescription } }
    func revealReports() { if let storage { NSWorkspace.shared.open(storage.directory) } }
    func export(_ type: ExportType) {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.title = "导出验机报告"
        panel.allowedContentTypes = [type == .pdf ? .pdf : type == .html ? .html : .json]
        panel.nameFieldStringValue = "Mac验机-\(report.startedAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)).replacingOccurrences(of: "/", with: "-"))-\(report.id.uuidString.prefix(8)).\(type.rawValue)"
        panel.message = "报告含完整设备序列号和人工备注，请妥善保管。"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch type {
            case .json: try ReportExporter.json(report).write(to: url, options: .atomic)
            case .html: try Data(ReportExporter.html(report).utf8).write(to: url, options: .atomic)
            case .pdf: try PDFExporter.write(report, to: url)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { errorMessage = "导出失败：\(error.localizedDescription)" }
    }
}

enum AppPage: String, CaseIterable, Identifiable {
    case overview = "验机工作台", manual = "人工检查", report = "验机报告", history = "历史记录"
    var id: Self { self }
    var symbol: String {
        switch self { case .overview: return "square.grid.2x2"; case .manual: return "checklist"; case .report: return "doc.text"; case .history: return "clock.arrow.circlepath" }
    }
}
enum ExportType: String, CaseIterable { case pdf, html, json }
