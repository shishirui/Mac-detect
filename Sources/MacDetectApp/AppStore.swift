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
    @Published var resetHost: ResetHost?
    @Published var isResetBusy = false
    @Published var resetPreparation = ResetPreparation()
    @Published var resetBackup: ResetBackupReceipt?
    @Published var showResetConfirmation = false
    @Published var resetMessage: String?
    private var preparedResetReportID: UUID?
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
        guard !isRunning, !isResetBusy else { return }
        clearResetConsent()
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
                        case .metrics(let ssd, let sensors): self.report?.ssdHealth = ssd; self.report?.sensors = sensors
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
        guard !isResetBusy else { return }; resetBackup = nil; showResetConfirmation = false
        guard let index = report?.manual.firstIndex(where: { $0.id == id }) else { return }
        if let state { report?.manual[index].state = state }
        if let note { report?.manual[index].note = String(note.prefix(4000)) }
        report?.manual[index].updatedAt = Date(); persist()
    }
    func setNotes(_ value: String) { guard !isResetBusy else { return }; resetBackup = nil; showResetConfirmation = false; report?.notes = String(value.prefix(16000)); persist() }
    func setAssetTag(_ value: String) { guard !isResetBusy else { return }; resetBackup = nil; showResetConfirmation = false; report?.assetTag = String(value.prefix(200)); persist() }
    func load(_ item: InspectionReport) {
        guard !isRunning, !isResetBusy else { return }
        clearResetConsent()
        report = item; mode = item.mode; selectedPage = .report
    }
    func persist() {
        guard let report, let storage else { return }
        do { try storage.save(report) }
        catch { errorMessage = "本地报告保存失败，请导出备份：\(error.localizedDescription)" }
    }
    func reloadHistory() { do { history = try storage?.all() ?? [] } catch { errorMessage = error.localizedDescription } }
    func revealReports() { if let storage { NSWorkspace.shared.open(storage.directory) } }
    func clearResetConsent() {
        resetPreparation = ResetPreparation(); resetBackup = nil
        showResetConfirmation = false; preparedResetReportID = nil; resetMessage = nil
    }
    var resetBlockers: [String] {
        ResetGate.blockers(host: resetHost, report: report, preparation: resetPreparation, backup: resetBackup, busy: isRunning || isResetBusy)
    }
    func refreshResetHost() {
        guard !isRunning, !isResetBusy else { return }
        isResetBusy = true; showResetConfirmation = false
        Task {
            do { resetHost = try await Task.detached(priority: .userInitiated) { try ResetHostProbe.read() }.value }
            catch { resetHost = nil; errorMessage = "读取本机信息失败：\(error.localizedDescription)" }
            isResetBusy = false
        }
    }
    func exportHandoff() {
        guard !isRunning, !isResetBusy, var updated = report, updated.finishedAt != nil else { return }
        let panel = NSOpenPanel(); panel.title = "选择交机包保存位置"
        panel.message = "建议选择 U 盘。若先保存到本机，请在抹除前将整个文件夹复制到另一台电脑。包含完整序列号和备注。"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let id = updated.id
        updated.schemaVersion = 3
        updated.resetRecord = updated.resetRecord ?? ResetRecord(); updated.resetRecord?.backupExportedAt = Date()
        isResetBusy = true; resetBackup = nil; resetPreparation.reportCopiedOffMac = false
        let host = resetHost
        Task {
            do {
                let snapshot = updated
                let directory = try await Task.detached(priority: .userInitiated) { try HandoffPackage.export(snapshot, host: host, into: folder) }.value
                if report?.id == id {
                    report = updated; persist()
                    resetBackup = ResetBackupReceipt(reportID: id, machineSerial: updated.machine.serial)
                    resetMessage = "交机包已导出。请确认已带离目标 Mac，再勾选“已保存到外部设备”。"
                }
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            } catch { errorMessage = "交机包导出失败：\(error.localizedDescription)" }
            isResetBusy = false
        }
    }
    func importHandoff() {
        guard !isRunning, !isResetBusy else { return }
        let panel = NSOpenPanel(); panel.title = "导入交机 JSON 报告"
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "导入为独立历史记录，不覆盖本机报告，也不恢复任何抹除授权。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try HandoffPackage.read(url)
            guard let storage else { throw SystemParsers.ParseError.missing("本地报告目录不可用") }
            try storage.save(imported)
            clearResetConsent(); report = imported; mode = imported.mode
            reloadHistory(); selectedPage = .reset
            resetMessage = "已导入历史记录。请核对目标序列号；抹除前自动检测结果保持原样，交机观察单独记录。"
        } catch { errorMessage = "无法导入报告：\(error.localizedDescription)" }
    }
    func setPostCheck(_ id: String, state: ManualState? = nil, note: String? = nil) {
        guard !isRunning, !isResetBusy, report != nil else { return }
        resetBackup = nil; showResetConfirmation = false
        report?.schemaVersion = 3
        report?.resetRecord = report?.resetRecord ?? ResetRecord()
        guard let index = report?.resetRecord?.postChecks.firstIndex(where: { $0.id == id }) else { return }
        if let state, [.unverified, .passed, .issue].contains(state) { report?.resetRecord?.postChecks[index].state = state }
        if let note { report?.resetRecord?.postChecks[index].note = String(note.prefix(4000)) }
        report?.resetRecord?.postChecks[index].updatedAt = Date(); persist()
    }
    func prepareResetConfirmation() {
        guard !isRunning, !isResetBusy, let id = report?.id else { return }
        isResetBusy = true; showResetConfirmation = false
        Task {
            do {
                let fresh = try await Task.detached(priority: .userInitiated) { try ResetHostProbe.read() }.value
                resetHost = fresh
                guard report?.id == id else { throw SystemParsers.ParseError.missing("所选报告已改变，请重新准备") }
                _ = try ResetGate.launchTarget(host: fresh, report: report, preparation: resetPreparation, backup: resetBackup, busy: isRunning)
                preparedResetReportID = id; showResetConfirmation = true
            } catch { errorMessage = error.localizedDescription }
            isResetBusy = false
        }
    }
    func openSystemEraseAssistant() {
        guard !isResetBusy, showResetConfirmation, preparedResetReportID == report?.id, var updated = report else { return }
        showResetConfirmation = false
        do {
            let target = try ResetGate.launchTarget(host: resetHost, report: report, preparation: resetPreparation, backup: resetBackup, busy: isRunning)
            guard Bundle(url: target)?.bundleIdentifier == "com.apple.EraseAssistant" else { throw SystemParsers.ParseError.missing("Apple 系统抹掉助理入口不可用，请按页面中的系统设置路径操作") }
            updated.resetRecord = updated.resetRecord ?? ResetRecord()
            updated.resetRecord?.assistantRequestedAt = Date(); updated.resetRecord?.assistantOpenedAt = nil; updated.resetRecord?.assistantError = nil
            guard let storage else { throw SystemParsers.ParseError.missing("无法保存准备记录，请先导出并修复本地记录目录") }
            try storage.save(updated) // If this fails, do not launch anything.
            report = updated; isResetBusy = true
            let id = updated.id
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            NSWorkspace.shared.openApplication(at: target, configuration: configuration) { [weak self] app, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isResetBusy = false; self.preparedResetReportID = nil
                    if self.report?.id == id {
                        if app != nil, error == nil {
                            self.report?.resetRecord?.assistantOpenedAt = Date()
                            self.resetMessage = "系统已接受打开抹掉助理的请求。请在 Apple 界面操作；抹除是否执行及完成仍未验证。"
                        } else {
                            let message = error?.localizedDescription ?? "系统未返回已打开的应用"
                            self.report?.resetRecord?.assistantError = message
                            self.errorMessage = "未能打开抹掉助理：\(message)。可手动前往系统设置 → 通用 → 传输或还原。"
                        }
                        self.persist()
                    }
                    // Every attempt consumes the preparation; never reuse consent.
                    self.resetPreparation = ResetPreparation(); self.resetBackup = nil
                }
            }
        } catch { preparedResetReportID = nil; errorMessage = error.localizedDescription }
    }
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
    case overview = "验机工作台", manual = "人工检查", report = "验机报告", reset = "交机与重置", history = "历史记录"
    var id: Self { self }
    var symbol: String {
        switch self { case .overview: return "square.grid.2x2"; case .manual: return "checklist"; case .report: return "doc.text"; case .reset: return "arrow.counterclockwise.circle"; case .history: return "clock.arrow.circlepath" }
    }
}
enum ExportType: String, CaseIterable { case pdf, html, json }
