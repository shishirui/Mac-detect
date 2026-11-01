import Foundation

public final class ReportStorage {
    public let directory: URL
    public init(directory: URL? = nil) throws {
        self.directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("MacDetect/Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func save(_ report: InspectionReport) throws {
        let url = directory.appendingPathComponent("\(report.id.uuidString).json")
        try ReportExporter.json(report).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func all() throws -> [InspectionReport] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> InspectionReport? in
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 4 * 1024 * 1024,
                      let data = try? Data(contentsOf: url), var report = try? decoder.decode(InspectionReport.self, from: data) else { return nil }
                // A process crash or power loss must never leave persisted "running" checks looking completed.
                if report.finishedAt == nil {
                    report.wasCancelled = true
                    if report.mode != .quick, report.sensors != nil {
                        report.sensors?.interrupted = true
                        for check in [report.sensors!.temperatureCheck(), report.sensors!.fanCheck(machine: report.machine)] {
                            if let index = report.checks.firstIndex(where: { $0.id == check.id }) { report.checks[index] = check }
                        }
                    }
                    for index in report.checks.indices where !report.checks[index].status.isFinished {
                        report.checks[index].status = .interrupted
                        report.checks[index].summary = "上次检测未正常完成，需重新验机"
                    }
                }
                return report
            }.sorted { $0.startedAt > $1.startedAt }
    }
}

public enum ReportExporter {
    public static func json(_ report: InspectionReport) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }
    public static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
    public static func html(_ report: InspectionReport) -> String {
        let rows = report.checks.map { check in
            "<section><div class='check'><h3>\(escape(check.title))</h3><span class='\(check.status.rawValue)'>\(check.status.title)</span></div><p>\(escape(check.summary))</p><ul>\(check.evidence.map { "<li>\(escape($0))</li>" }.joined())</ul></section>"
        }.joined()
        let manual = report.manual.map { check in
            "<section><div class='check'><h3>\(escape(check.title))</h3><b>\(check.state.title)\(check.isResolved ? "" : " · 待完成")</b></div><p>\(escape(check.instructions))</p><p>操作人备注：\(escape(check.note.isEmpty ? "未填写" : check.note))</p></section>"
        }.joined()
        return """
        <!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Mac验机报告</title>
        <style>body{font:14px/1.7 -apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif;color:#192d39;background:#f4f6f7;margin:0}main{max-width:860px;margin:32px auto;background:white;padding:48px}h1{font-size:30px;margin:8px 0}h2{margin-top:32px}h3{font-size:16px;margin:0}.eyebrow{letter-spacing:3px;color:#527063}.verdict{padding:18px;background:#edf5f0;border-left:4px solid #33775b}.meta{white-space:pre-wrap;color:#52616a}section{border-bottom:1px solid #dde4e8;padding:18px 0;break-inside:avoid}.check{display:flex;justify-content:space-between;gap:20px}li{color:#64717a}.passed{color:#1f7352}.failed{color:#b33232}.warning{color:#8e5a0c}footer{margin-top:32px;color:#65737a;font-size:12px}p{overflow-wrap:anywhere;white-space:pre-wrap}@media print{body{background:white}main{margin:0;padding:0;max-width:none}@page{size:A4;margin:18mm}}</style>
        <main><div class="eyebrow">MAC DETECT · LOCAL INSPECTION</div><h1>Mac 验机报告</h1><p class="verdict">\(escape(report.verdict))</p><div class="meta">\(escape(metadata(report)))</div><h2>自动检测 · \(report.passedCount) / \(report.checks.count) 项通过</h2>\(rows)<h2>人工验机记录</h2><p>以下状态由操作人填写，不代表软件自动验证。</p>\(manual)<h2>收购备注</h2><p>\(escape(report.notes.isEmpty ? "未填写" : report.notes))</p><footer>\(escape(InspectionReport.limitations))<p>本地生成的验机记录，不是 Apple 认证或防篡改鉴定证书。报告包含设备序列号，请仅与相关交易人员分享。</p></footer></main></html>
        """
    }
    public static func metadata(_ report: InspectionReport) -> String {
        let machine = report.machine
        return """
        报告编号：\(report.id.uuidString)
        检测开始：\(report.startedAt.formatted(date: .numeric, time: .standard))
        检测结束：\(report.finishedAt?.formatted(date: .numeric, time: .standard) ?? "未正常结束 / 检测中")
        模式：\(report.mode.title) · 软件版本 \(report.softwareVersion)
        资产编号：\(report.assetTag.isEmpty ? "未填写" : report.assetTag)
        设备：\(machine.model) · \(machine.modelIdentifier)
        芯片：\(machine.chip) · \(machine.cores) · 内存 \(machine.memory)
        系统盘容量：\(machine.storage) · 可用 \(machine.freeStorage)
        系统：\(machine.system) · \(machine.architecture)
        序列号：\(machine.serial)
        """
    }
    public static func text(_ report: InspectionReport) -> String {
        var lines = ["Mac 验机报告", report.verdict, metadata(report), "自动检测"]
        for check in report.checks {
            lines += ["\n\(check.title)  ·  \(check.status.title)", check.summary]
            lines += check.evidence.map { "• \($0)" }
        }
        lines.append("\n人工验机记录（由操作人填写）")
        for check in report.manual {
            lines += ["\n\(check.title)  ·  \(check.state.title)\(check.isResolved ? "" : " · 待完成")", check.instructions, "备注：\(check.note.isEmpty ? "未填写" : check.note)"]
        }
        lines += ["\n收购备注", report.notes.isEmpty ? "未填写" : report.notes, "\n检测边界", InspectionReport.limitations, "本地生成的验机记录，不是 Apple 认证或防篡改鉴定证书。报告包含设备序列号，请妥善保管。"]
        return lines.joined(separator: "\n")
    }
}
