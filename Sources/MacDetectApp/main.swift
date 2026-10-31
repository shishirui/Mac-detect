import Foundation
import AppKit
import SwiftUI
import MacDetectCore

let arguments = CommandLine.arguments
func argument(_ key: String) -> String? {
    guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
if let worker = argument("--worker") {
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
} else if let destination = argument("--quick-report") {
    let report = Scanner(mode: .quick, executable: arguments[0], token: CancellationToken(), emit: { _ in }).run()
    do {
        let url = URL(fileURLWithPath: destination)
        try ReportExporter.json(report).write(to: url, options: .atomic)
        try Data(ReportExporter.html(report).utf8).write(to: url.deletingPathExtension().appendingPathExtension("html"), options: .atomic)
        try PDFExporter.write(report, to: url.deletingPathExtension().appendingPathExtension("pdf"))
        print("只读快速筛查完成：\(report.passedCount)/\(report.checks.count) 项通过；\(report.verdict)。报告已写入指定目录。")
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
