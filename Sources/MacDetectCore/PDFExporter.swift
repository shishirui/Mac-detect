import Foundation
import AppKit
import CoreText

/// Keeps ordinary check sections together; very long operator notes flow across pages.
public enum PDFExporter {
    private static let ink = NSColor(calibratedRed: 0.10, green: 0.19, blue: 0.18, alpha: 1)
    private static let green = NSColor(calibratedRed: 0.15, green: 0.42, blue: 0.32, alpha: 1)
    private static let gray = NSColor(calibratedWhite: 0.40, alpha: 1)
    private static func line(_ text: String, size: CGFloat = 10.5, weight: NSFont.Weight = .regular, color: NSColor = ink) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3; paragraph.paragraphSpacing = 5
        return NSAttributedString(string: text + "\n", attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph])
    }
    public static func write(_ report: InspectionReport, to url: URL) throws {
        var blocks: [NSAttributedString] = []
        let hero = NSMutableAttributedString()
        hero.append(line("MAC DETECT  /  LOCAL INSPECTION", size: 9, weight: .semibold, color: green))
        hero.append(line("Mac 验机报告", size: 26, weight: .semibold))
        hero.append(line(report.verdict, size: 13, weight: .medium, color: report.hasIssue ? .systemRed : green))
        blocks.append(hero)
        blocks.append(line(ReportExporter.metadata(report), size: 10, color: gray))
        for (index, check) in report.checks.enumerated() {
            let block = NSMutableAttributedString()
            if index == 0 { block.append(line("01  自动检测  ·  \(report.passedCount) / \(report.checks.count) 项通过", size: 15, weight: .semibold, color: green)) }
            block.append(line("\(check.title)  ·  \(check.status.title)", size: 12, weight: .semibold))
            block.append(line(check.summary))
            check.evidence.forEach { block.append(line("• \($0)", size: 9.5, color: gray)) }
            if let seconds = check.elapsed { block.append(line("耗时：\(String(format: "%.1f", seconds)) 秒", size: 9, color: gray)) }
            blocks.append(block)
        }
        for (index, item) in report.manual.enumerated() {
            let block = NSMutableAttributedString()
            if index == 0 {
                block.append(line("02  人工验机记录", size: 15, weight: .semibold, color: green))
                block.append(line("以下状态由操作人填写，不代表软件自动验证。", size: 9.5, color: gray))
            }
            block.append(line("\(item.title)  ·  \(item.state.title)\(item.isResolved ? "" : " · 待完成")", size: 12, weight: .semibold))
            block.append(line(item.instructions, size: 10, color: gray))
            block.append(line("备注：\(item.note.isEmpty ? "未填写" : item.note)", size: 10))
            blocks.append(block)
        }
        let notes = NSMutableAttributedString()
        notes.append(line("03  收购备注", size: 15, weight: .semibold, color: green))
        notes.append(line(report.notes.isEmpty ? "未填写" : report.notes))
        blocks.append(notes)
        let limits = NSMutableAttributedString()
        limits.append(line("检测边界", size: 12, weight: .semibold))
        limits.append(line(InspectionReport.limitations, size: 9.5, color: gray))
        limits.append(line("本地生成的验机记录，不是 Apple 认证或防篡改鉴定证书。报告包含设备序列号，请妥善保管。", size: 9.5, color: gray))
        blocks.append(limits)

        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw SystemParsers.ParseError.missing("无法创建 PDF")
        }
        let top: CGFloat = 790, bottom: CGFloat = 58, width: CGFloat = 507
        var y = top, page = 0
        func beginPage() {
            context.beginPDFPage(nil); page += 1; y = top
            context.setStrokeColor(NSColor(calibratedWhite: 0.85, alpha: 1).cgColor)
            context.setLineWidth(0.5); context.move(to: CGPoint(x: 44, y: 43)); context.addLine(to: CGPoint(x: 551, y: 43)); context.strokePath()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 44, y: 27)
            CTLineDraw(CTLineCreateWithAttributedString(line("MAC DETECT  /  \(report.softwareVersion)  ·  \(report.id.uuidString.prefix(8))", size: 8, color: gray)), context)
            context.textPosition = CGPoint(x: 531, y: 27)
            CTLineDraw(CTLineCreateWithAttributedString(line("\(page)", size: 8, color: gray)), context)
        }
        beginPage()
        for block in blocks {
            let framesetter = CTFramesetterCreateWithAttributedString(block)
            var offset = 0
            let fullHeight = ceil(CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil).height) + 2
            if y < top && (fullHeight <= top - bottom ? fullHeight > y - bottom : y - bottom < 100) {
                context.endPDFPage(); beginPage()
            }
            while offset < block.length {
                let available = y - bottom
                let remainingHeight = ceil(CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: offset, length: 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil).height) + 2
                let height = min(available, remainingHeight)
                let path = CGPath(rect: CGRect(x: 44, y: y - height, width: width, height: height), transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
                let range = CTFrameGetVisibleStringRange(frame)
                if range.length == 0 {
                    if y == top { context.endPDFPage(); context.closePDF(); throw SystemParsers.ParseError.missing("PDF 分页失败") }
                    context.endPDFPage(); beginPage(); continue
                }
                context.textMatrix = .identity; CTFrameDraw(frame, context)
                offset += range.length; y -= height
                if offset < block.length { context.endPDFPage(); beginPage() }
            }
            y -= 14
        }
        context.endPDFPage(); context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }
}
