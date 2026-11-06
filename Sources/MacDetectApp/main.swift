import Foundation
import AppKit
import SwiftUI
import MacDetectCore

let arguments = CommandLine.arguments
func argument(_ key: String) -> String? {
    guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
if let destination = argument("--reset-readiness-report") {
    do {
        let host = try ResetHostProbe.read()
        let data = try JSONEncoder().encode(host)
        let url = URL(fileURLWithPath: destination)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        print("只读重置条件检查完成；未启动抹除、重启或系统抹掉助理。")
    } catch { fputs("读取失败：\(error.localizedDescription)\n", stderr); exit(1) }
} else if let disk = argument("--probe-nvme") {
    if let data = try? JSONEncoder().encode(SSDProbe.read(disk: disk)) { FileHandle.standardOutput.write(data) }
} else if arguments.contains("--probe-sensors") {
    if let data = try? JSONEncoder().encode(SensorReader().sample()) { FileHandle.standardOutput.write(data) }
} else if let path = argument("--monitor-sensors"), let parent = Int32(argument("--parent-pid") ?? "") {
    do { try SensorHelper.monitor(destination: URL(fileURLWithPath: path), parentPID: parent) }
    catch { exit(1) }
} else if let worker = argument("--worker") {
    let seconds = Double(argument("--seconds") ?? "1") ?? 1
    let mib = Int(argument("--mib") ?? "256") ?? 256
    let outcome: WorkerOutcome
    switch worker {
    case "cpu": outcome = Workers.cpu(seconds: seconds)
    case "memory": outcome = Workers.memory(seconds: seconds, mebibytes: mib)
    case "gpu": outcome = Workers.gpu(seconds: seconds)
    case "disk":
        if let directory = argument("--directory") { outcome = Workers.disk(directory: URL(fileURLWithPath: directory), mebibytes: mib) }
        else { outcome = .init(.unavailable, "没有提供专用临时测试目录") }
    default: outcome = .init(.unavailable, "未知检测项目")
    }
    if let data = try? JSONEncoder().encode(outcome) { FileHandle.standardOutput.write(data) }
} else if arguments.contains("--quick-report") || arguments.contains("--standard-report") {
    let reportFlags = arguments.filter { $0 == "--quick-report" || $0 == "--standard-report" }
    guard reportFlags.count == 1, let flag = reportFlags.first,
          let destination = argument(flag), !destination.isEmpty, !destination.hasPrefix("--") else {
        fputs("用法：MacDetect --quick-report <报告.json> 或 MacDetect --standard-report <报告.json>；请选择一种模式并提供输出路径。\n", stderr)
        exit(2)
    }
    let mode: InspectionMode = flag == "--standard-report" ? .standard : .quick
    if mode == .standard { fputs("开始标准验机（\(mode.estimate)）：\(mode.detail)\n", stderr) }
    let report = Scanner(mode: mode, executable: arguments[0], token: CancellationToken(), emit: { event in
        if mode == .standard, case .result(let result) = event, result.status == .running {
            fputs("正在检测：\(result.title)\n", stderr)
        }
    }).run()
    do {
        let url = URL(fileURLWithPath: destination)
        try ReportExporter.json(report).write(to: url, options: .atomic)
        try Data(ReportExporter.html(report).utf8).write(to: url.deletingPathExtension().appendingPathExtension("html"), options: .atomic)
        try PDFExporter.write(report, to: url.deletingPathExtension().appendingPathExtension("pdf"))
        let label = mode == .quick ? "只读快速筛查" : mode.title
        print("\(label)完成：\(report.passedCount)/\(report.checks.count) 项通过；\(report.verdict)。报告已写入指定目录。")
    } catch { fputs("报告失败：\(error.localizedDescription)\n", stderr); exit(1) }
} else {
    MacDetectApplication.main()
}

struct MacDetectApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore()
    var body: some Scene {
        WindowGroup("Mac 验机助手") {
            ContentView().environmentObject(store)
                .frame(minWidth: 1080, minHeight: 740)
                .onAppear { delegate.store = store }
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1220, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .saveItem) {
                Button("导出 PDF 报告…") { store.export(.pdf) }.keyboardShortcut("e", modifiers: [.command]).disabled(store.report == nil || store.isRunning)
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.isRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "停止检测并退出？"
        alert.informativeText = "正在运行的检测将停止，已完成的结果会保存在本机。未完成项目不会计为通过。"
        alert.addButton(withTitle: "继续检测"); alert.addButton(withTitle: "停止并退出")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        store.afterStopped = { NSApp.reply(toApplicationShouldTerminate: true) }
        store.stop()
        return .terminateLater
    }
}
