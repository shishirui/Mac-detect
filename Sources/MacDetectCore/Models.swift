import Foundation

public let appVersion = "0.2.0"

public enum InspectionMode: String, Codable, CaseIterable, Identifiable {
    case quick, standard, extended
    public var id: String { rawValue }
    public var title: String {
        switch self { case .quick: return "快速筛查"; case .standard: return "标准验机"; case .extended: return "深度验机" }
    }
    public var estimate: String {
        switch self { case .quick: return "约 1–3 分钟"; case .standard: return "约 15–25 分钟"; case .extended: return "约 60–90 分钟" }
    }
    public var detail: String {
        switch self {
        case .quick: return "读取配置、磁盘健康和管理状态，不运行压力测试。"
        case .standard: return "CPU、内存、GPU 各测试 5 分钟，磁盘最多写入 512 MiB。"
        case .extended: return "CPU、内存各 20 分钟，GPU 15 分钟，磁盘最多写入 1 GiB。"
        }
    }
    public var cpuSeconds: Double { self == .extended ? 1200 : 300 }
    public var memorySeconds: Double { cpuSeconds }
    public var gpuSeconds: Double { self == .extended ? 900 : 300 }
    public var diskMiB: Int { self == .extended ? 1024 : 512 }
}

public enum CheckStatus: String, Codable, CaseIterable {
    case pending, running, passed, warning, failed, unavailable, skipped, interrupted, notApplicable
    public var title: String {
        switch self {
        case .notApplicable: return "不适用"
        case .pending: return "待检测"
        case .running: return "检测中"
        case .passed: return "通过"
        case .warning: return "需要复核"
        case .failed: return "发现异常"
        case .unavailable: return "无法验证"
        case .skipped: return "未检测"
        case .interrupted: return "已中断"
        }
    }
    public var symbol: String {
        switch self {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .unavailable: return "questionmark.circle"
        case .interrupted: return "pause.circle"
        default: return "circle.dashed"
        }
    }
    public var isFinished: Bool { self != .pending && self != .running }
}

public enum CheckCategory: String, Codable {
    case configuration = "机器信息", storage = "存储", performance = "稳定性", security = "交机风险", system = "系统记录"
}

public struct CheckResult: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var category: CheckCategory
    public var status: CheckStatus
    public var summary: String
    public var evidence: [String]
    public var elapsed: Double?
    public init(_ id: String, _ title: String, _ category: CheckCategory, status: CheckStatus = .pending, summary: String = "等待检测", evidence: [String] = [], elapsed: Double? = nil) {
        self.id = id; self.title = title; self.category = category; self.status = status
        self.summary = summary; self.evidence = evidence; self.elapsed = elapsed
    }
    public static var initial: [CheckResult] { [
        .init("hardware", "硬件配置", .configuration),
        .init("storage", "系统磁盘健康", .storage),
        .init("ssdDetail", "SSD 磨损与累计写入", .storage),
        .init("activation", "激活锁状态", .security),
        .init("management", "企业管理状态", .security),
        .init("panic", "近期内核崩溃记录", .system),
        .init("thermal", "系统热状态", .system),
        .init("temperature", "温度传感器", .system),
        .init("fans", "风扇转速", .system),
        .init("cpu", "CPU 运算校验", .performance),
        .init("memory", "内存读写校验", .performance),
        .init("gpu", "GPU 计算校验", .performance),
        .init("disk", "磁盘抽样读写校验", .storage)
    ] }
}

public struct MachineInfo: Codable, Equatable {
    public var model: String = "等待识别"
    public var modelIdentifier: String = "—"
    public var chip: String = "—"
    public var cores: String = "—"
    public var memory: String = "—"
    public var serial: String = "—"
    public var system: String = ProcessInfo.processInfo.operatingSystemVersionString
    public var architecture: String = "—"
    public var storage: String = "—"
    public var freeStorage: String = "—"
    public init() {}
}

public enum ManualState: String, Codable, CaseIterable {
    case unverified, passed, issue, notApplicable
    public var title: String {
        switch self { case .unverified: return "未验证"; case .passed: return "已验证通过"; case .issue: return "发现问题"; case .notApplicable: return "不适用" }
    }
}

public struct ManualCheck: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var instructions: String
    public var state: ManualState = .unverified
    public var note: String = ""
    public var updatedAt: Date?
    public var requiresNote: Bool { state == .notApplicable || state == .issue }
    public var isResolved: Bool { state != .unverified && (!requiresNote || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    public static var defaults: [ManualCheck] { [
        .init(id: "appearance", title: "外观与维修痕迹", instructions: "检查外壳、螺丝、接口、腐蚀、异味及风扇异响。核对机身与报告序列号。软件不能确认原装或排除进水维修。"),
        .init(id: "usb", title: "USB 接口 · 逐口检查", instructions: "用确认正常的 U 盘或 SSD 逐个连接所有 USB 接口，实际复制并读回文件。记录已测试的端口位置，轻触接头检查是否断连。"),
        .init(id: "thunderbolt", title: "雷雳 / USB4", instructions: "使用对应协议的设备及线材，逐口确认连接和传输。普通 USB-C U 盘通过不等于雷雳通过；缺少设备请保留未验证。"),
        .init(id: "display", title: "HDMI 与 USB-C 显示", instructions: "逐个验证支持视频输出的端口，检查目标分辨率、刷新率、花屏和黑屏。换用已知正常的显示器及线材复核。"),
        .init(id: "ethernet", title: "有线网络", instructions: "接入已知正常的网线和路由器，确认协商速率，持续传输局域网文件并观察断连。没有以太网接口的机型可填不适用并说明。"),
        .init(id: "wifi", title: "Wi-Fi", instructions: "连接已知正常的无线网络，实际传输文件、观察连接稳定性；仅能发现网络不能证明无线功能正常。"),
        .init(id: "bluetooth", title: "蓝牙", instructions: "实际配对鼠标、键盘或耳机并持续使用，观察断连和延迟。"),
        .init(id: "audio", title: "扬声器与耳机接口", instructions: "播放声音，分别检查内置扬声器和支持的耳机输出，确认无破音、杂音。Mac mini 没有内置麦克风，不据此判故障。"),
        .init(id: "power", title: "重启、睡眠与唤醒", instructions: "先保存检测结果，再手动重启及睡眠唤醒，检查显示、网络和外设是否恢复。不要在压力测试中执行。"),
        .init(id: "diagnostics", title: "Apple 官方诊断", instructions: "先保存报告。Apple 芯片：关机，长按电源至启动选项，再按 Command-D。Intel：开机时按住 D。按官方指引操作，记录诊断代码；无错误代码也不保证无隐患。"),
        .init(id: "transfer", title: "解除激活锁与交机激活", instructions: "由卖家备份数据、退出账户并关闭“查找”，在卖家授权下抹掉电脑，联网走完设置验证无需原主账户。应用不执行抹掉操作。软件内显示关闭仍不能替代此步骤。"),
        .init(id: "organization", title: "企业管理与来源核验", instructions: "核实来源。企业设备应由原组织解除管理并从 Apple Business / School Manager 释放，保留凭证，抹掉后联网检查设置流程。未出现管理提示不等于能证明云端永无绑定。"),
        .init(id: "repair", title: "维修状态核验（支持的机型）", instructions: "询问维修历史并查看凭证。Apple 芯片与 macOS 26 及以上，在系统支持时通过维修助理检查未完成维修。系统未提供该功能时说明原因，不能据此判定从未维修。")
    ] }
}

public struct InspectionReport: Codable, Identifiable {
    public var schemaVersion: Int = 2
    public var softwareVersion: String = appVersion
    public var id: UUID = UUID()
    public var startedAt: Date = Date()
    public var finishedAt: Date?
    public var mode: InspectionMode
    public var machine: MachineInfo = .init()
    public var checks: [CheckResult] = CheckResult.initial
    public var manual: [ManualCheck] = ManualCheck.defaults
    public var assetTag: String = ""
    public var notes: String = ""
    public var ssdHealth: SSDHealth?
    public var sensors: SensorSession?
    public var wasCancelled = false
    public init(mode: InspectionMode) { self.mode = mode }
    public var passedCount: Int { checks.filter { $0.status == .passed }.count }
    public var unresolvedCount: Int { checks.filter { $0.status != .passed && $0.status != .notApplicable }.count + manual.filter { !$0.isResolved }.count }
    public var hasIssue: Bool { checks.contains { $0.status == .failed } || manual.contains { $0.state == .issue } }
    public var verdict: String {
        if hasIssue { return "发现异常 · 建议暂停收购" }
        if checks.contains(where: { $0.status == .warning }) { return "需要复核 · 暂勿据此完成收购" }
        if wasCancelled { return "检测已中断 · 验机尚未完成" }
        if unresolvedCount > 0 { return "验机未完成 · 仍有未验证项目" }
        return "本次验机未发现异常"
    }
    public static let limitations = "通过仅表示本次测试范围与时长内未发现异常，不保证未来可靠性，不证明原装、无进水或无维修。用户态内存测试不覆盖全部物理内存，磁盘测试仅覆盖临时文件，GPU 校验不替代显示输出测试。系统数据可能缺失或受当前系统影响；无日志不代表无故障。本机管理状态无法证明组织云端绑定已解除。"
}

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

public struct WorkerOutcome: Codable {
    public var status: CheckStatus
    public var summary: String
    public var evidence: [String]
    public init(_ status: CheckStatus, _ summary: String, _ evidence: [String] = []) {
        self.status = status; self.summary = summary; self.evidence = evidence
    }
}
