import Foundation

public enum ResetHardware: String, Codable {
    case appleSilicon, intelT2, intelUnconfirmed, unknown
    public var title: String {
        switch self {
        case .appleSilicon: return "Apple 芯片"
        case .intelT2: return "Intel · 已识别 T2"
        case .intelUnconfirmed: return "Intel · 未确认 T2"
        case .unknown: return "芯片类型未确认"
        }
    }
    public static func identify(arm64: String?, machine: MachineInfo, bridge: Data?) -> ResetHardware {
        // sysctl reflects the host even when the executable runs under Rosetta.
        if arm64?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return .appleSilicon }
        guard machine.chip.localizedCaseInsensitiveContains("Intel") else { return .unknown }
        if let bridge, let root = try? JSONSerialization.jsonObject(with: bridge) as? [String: Any],
           let rows = root["SPiBridgeDataType"] as? [[String: Any]],
           rows.contains(where: { row in
               ["ibridge_model_name", "ibridge_model_identifier"].contains { key in
                   guard let value = row[key] as? String else { return false }
                   return ["Apple T2 Security Chip", "Apple T2 chip", "Apple T2", "apple_t2"].contains(value)
               }
           }) { return .intelT2 }
        // Apple's documented 2018 Mac mini is Macmini8,1. Do not infer T2 for
        // arbitrary Intel models, empty bridge output, or similarly named chips.
        if machine.modelIdentifier == "Macmini8,1" { return .intelT2 }
        return .intelUnconfirmed
    }
}

public struct ResetHost: Codable, Equatable {
    public var machine: MachineInfo
    public var hardware: ResetHardware
    public var osMajor: Int
    public var internalBoot: Bool?
    public var eraseAssistantAvailable: Bool
    public var activation: CheckResult
    public var management: CheckResult
    public var capturedAt: Date
    public var supportsQuickErase: Bool { osMajor >= 12 && [.appleSilicon, .intelT2].contains(hardware) && eraseAssistantAvailable && internalBoot == true }
    public var routeExplanation: String {
        if supportsQuickErase { return "此机支持系统快速抹除入口；最终可用性与认证要求由 Apple 抹掉助理检查。" }
        if ![.appleSilicon, .intelT2].contains(hardware) { return "未确认满足 Apple 芯片 / T2 条件，请使用按机型提供的恢复模式指引。" }
        if internalBoot != true { return "未确认从内置磁盘启动，暂不提供快速抹除入口。" }
        return "当前系统版本或抹掉助理入口不满足条件，请使用恢复模式指引。"
    }
    public var identityIsKnown: Bool { Self.validSerial(machine.serial) && machine.modelIdentifier != "—" }
    public static func validSerial(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9]{8,20}$", options: .regularExpression) != nil
    }
    public func matches(_ report: InspectionReport) -> Bool {
        identityIsKnown && machine.serial == report.machine.serial && machine.modelIdentifier == report.machine.modelIdentifier
    }
}

public enum ResetHostProbe {
    public static let eraseAssistantURL = URL(fileURLWithPath: "/System/Library/CoreServices/Erase Assistant.app", isDirectory: true)
    public static func read() throws -> ResetHost {
        let token = CancellationToken()
        func run(_ path: String, _ args: [String]) throws -> CommandOutput {
            let value = try ProcessRunner.run(path, args, timeout: 25, cancellation: token)
            if let reason = value.interruption { throw SystemParsers.ParseError.missing(reason) }
            return value
        }
        let info = try run("/usr/sbin/system_profiler", ["SPHardwareDataType", "SPiBridgeDataType", "-json"])
        guard info.exitCode == 0 else { throw SystemParsers.ParseError.missing("当前机器身份读取失败") }
        let (machine, activation) = try SystemParsers.hardware(info.data)
        let arm = try? run("/usr/sbin/sysctl", ["-n", "hw.optional.arm64"])
        let disk = try? run("/usr/sbin/diskutil", ["info", "-plist", "/"])
        var internalBoot: Bool?
        if let disk, disk.exitCode == 0, let object = try? PropertyListSerialization.propertyList(from: disk.data, format: nil) as? [String: Any] { internalBoot = object["Internal"] as? Bool }
        let profiles = try? run("/usr/bin/profiles", ["status", "-type", "enrollment"])
        let management = SystemParsers.management(profiles?.text ?? "", exitCode: profiles?.exitCode ?? -1)
        let available = Bundle(url: eraseAssistantURL)?.bundleIdentifier == "com.apple.EraseAssistant"
        return .init(machine: machine, hardware: ResetHardware.identify(arm64: arm?.exitCode == 0 ? arm?.text : nil, machine: machine, bridge: info.data),
                     osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, internalBoot: internalBoot,
                     eraseAssistantAvailable: available, activation: activation, management: management, capturedAt: Date())
    }
}

/// Session-only consent. Neither imported reports nor relaunching can restore it.
public struct ResetPreparation: Equatable {
    public var authorizedAndBackedUp = false
    public var reportCopiedOffMac = false
    public var accountsReviewed = false
    public var powerAndAccessoriesReady = false
    public var serialSuffix = ""
    public init() {}
}
public struct ResetBackupReceipt: Equatable {
    public var reportID: UUID
    public var machineSerial: String
    public var createdAt: Date
    public init(reportID: UUID, machineSerial: String, createdAt: Date = Date()) {
        self.reportID = reportID; self.machineSerial = machineSerial; self.createdAt = createdAt
    }
}
public enum ResetGate {
    public static func blockers(host: ResetHost?, report: InspectionReport?, preparation: ResetPreparation, backup: ResetBackupReceipt?, busy: Bool, now: Date = Date()) -> [String] {
        var reasons: [String] = []
        if busy { reasons.append("检测或准备任务正在进行，请先等待结束。") }
        guard let host else { return reasons + ["请先读取当前这台 Mac 的信息。"] }
        if !(0...300).contains(now.timeIntervalSince(host.capturedAt)) { reasons.append("本机信息已过期，请重新识别。") }
        if !host.identityIsKnown { reasons.append("无法确认本机身份，不能启动重置入口。") }
        if !host.supportsQuickErase { reasons.append(host.routeExplanation) }
        if host.management.status == .warning || host.management.status == .failed { reasons.append("本机报告存在企业管理，请先由原组织处理并重新检查。") }
        guard let report else { return reasons + ["请先对本机完成一次快速筛查并导出交机包。"] }
        if !host.matches(report) { reasons.append("所选报告与当前 Mac 不匹配；不能使用另一台机器的报告继续。") }
        if report.finishedAt == nil { reasons.append("所选验机记录尚未结束。") }
        if let backup, backup.reportID == report.id, backup.machineSerial == host.machine.serial, (0...86400).contains(now.timeIntervalSince(backup.createdAt)) {} else {
            reasons.append("请在本次会话中导出这份报告的交机包。")
        }
        if !preparation.authorizedAndBackedUp { reasons.append("请确认所有者已授权清除，且需要保留的数据已备份。") }
        if !preparation.reportCopiedOffMac { reasons.append("请确认交机包已保存到 U 盘或另一台电脑。") }
        if !preparation.accountsReviewed { reasons.append("请核实账户与组织归属，必要时请原主在场输入密码。") }
        if !preparation.powerAndAccessoriesReady { reasons.append("请接通电源、准备可用网络，并移除无关外置存储设备。") }
        if preparation.serialSuffix.uppercased() != String(host.machine.serial.suffix(4)).uppercased() || preparation.serialSuffix.count != 4 { reasons.append("请输入本机序列号末 4 位，确认操作对象。") }
        return reasons
    }
    /// Produces only a launch target. It has no erase, reboot, password or sudo path.
    public static func launchTarget(host: ResetHost?, report: InspectionReport?, preparation: ResetPreparation, backup: ResetBackupReceipt?, busy: Bool, now: Date = Date()) throws -> URL {
        let reasons = blockers(host: host, report: report, preparation: preparation, backup: backup, busy: busy, now: now)
        guard reasons.isEmpty else { throw SystemParsers.ParseError.missing(reasons.joined(separator: "\n")) }
        return ResetHostProbe.eraseAssistantURL
    }
}

public enum ResetGoal: String, CaseIterable, Identifiable {
    case quickErase, reinstall, recoveryErase, dfu
    public var id: Self { self }
    public var title: String {
        switch self {
        case .quickErase: return "快速清空交机"
        case .reinstall: return "保留数据重装"
        case .recoveryErase: return "恢复模式抹除"
        case .dfu: return "无法启动 · DFU"
        }
    }
}
public struct ResetGuide {
    public var title: String
    public var detail: String
    public var steps: [String]
    public var links: [(title: String, url: URL)]
    public static func make(goal: ResetGoal, hardware: ResetHardware) -> ResetGuide {
        let recovery: String
        switch hardware {
        case .appleSilicon: recovery = "保存工作并关机。长按电源按钮，看到启动选项后松开，选择“选项”→“继续”进入恢复模式。"
        case .intelT2, .intelUnconfirmed: recovery = "保存工作并关机。开机后立即按住 Command-R，直到出现 Apple 标志或地球。Mac mini 建议使用有线键盘；本地恢复不可用时可尝试 Option-Command-R。"
        case .unknown: recovery = "先确认芯片类型：Apple 芯片关机后长按电源进入启动选项；Intel 开机时按住 Command-R。不要根据其他机器的报告选择步骤。"
        }
        func link(_ title: String, _ article: String) -> (title: String, url: URL) { (title, URL(string: "https://support.apple.com/zh-cn/" + article)!) }
        switch goal {
        case .quickErase:
            return .init(title: "抹掉用户内容，保留当前 macOS", detail: "适用于 Apple 芯片或 T2 Mac，要求 macOS 12 或更新版本。实际抹除会删除本机所有用户的数据、设置和 App，包括验机助手及本地报告。",
                         steps: ["先备份卖家需要保留的数据，并把交机包带离这台 Mac。", "核实“查找”与企业归属。系统可能要求管理员及原 Apple 账户密码；这些密码只在 Apple 系统界面输入。", "Apple 芯片且 macOS 26 或更新版本：维修过或维修史不明时，先用系统维修助理检查未完成维修。", "在下方完成准备，再打开系统抹掉助理。若入口不可用，手动进入系统设置 → 通用 → 传输或还原 → 抹掉所有内容和设置。", "在 Apple 系统界面再次核对并决定是否继续；如果出现 Boot Camp / 额外宗卷提示，按官方说明处理，勿自行猜测要删除的磁盘。", "重启后按提示连接网络激活。准备出售时可停留在设置助理；出现原主账户或远程管理要求时，联系原主 / 原组织处理。"],
                         links: [link("Apple：抹掉所有内容和设置", "102664")])
        case .reinstall:
            return .init(title: "通过恢复模式重新安装 macOS", detail: "仅选择“重新安装 macOS”会保留应用与个人数据，适合修复系统。仍应先备份；交机清空请改选抹除流程。",
                         steps: ["备份重要文件，接通电源并准备可访问 Apple 服务的网络。", recovery, "选择“重新安装 macOS”并按提示操作。不要先执行磁盘工具的抹掉操作。", "系统可能要求解锁启动磁盘。让安装自行完成，期间可能多次重启。", "重新安装的版本由恢复环境决定，不承诺能任意降级。完成后重新运行验机，检查原来的问题是否仍存在。"],
                         links: [link("Apple：进入恢复模式", "102518"), link("Apple：重新安装 macOS", "102655")])
        case .recoveryErase:
            return .init(title: "在恢复模式抹除后重新安装", detail: "适合无法使用快速抹除的机器。抹掉会永久清除所选宗卷中的数据；所有磁盘选择与最终确认由用户在恢复环境完成。",
                         steps: ["备份并导出交机包；先核实激活锁、固件密码及企业归属，移除无关外置存储。", recovery, "先打开下方与芯片对应的 Apple 磁盘抹除指南，在另一台设备上保留步骤。具体磁盘 / 宗卷组选择依机型而异。", "在恢复环境中按官方指南操作磁盘工具，核对目标磁盘及数据清除范围后再确认。不要照抄其他机器的 disk 编号。", "退出磁盘工具，选择重新安装 macOS，保持电源与网络连接。", "安装后联网核验激活与远程管理提示。报告中只记录实际观察结果；尚未走到相关步骤就保留未验证。"],
                         links: [link("Apple：进入恢复模式", "102518"), link("Apple：Apple 芯片 Mac 抹除指南", "102506"), link("Apple：Intel Mac 抹除指南", "102639"), link("Apple：重新安装 macOS", "102655")])
        case .dfu:
            return .init(title: "用另一台 Mac 修复无法启动的设备", detail: "本页是双机操作指引，当前运行软件的 Mac 是辅助机，不会对它发起抹除。适用于 Apple 芯片 / T2 目标机；普通 Intel 机型使用恢复模式。",
                         steps: ["准备另一台运行 macOS 14 或更新版本、联网且有足够空间的 Mac，以及支持数据和充电的 USB-C 线；Apple 不建议使用雷雳 3 线完成此流程。", "根据目标 Mac 的准确型号，在下方官方端口图中找到 DFU 端口。Mac mini 不同代际端口位置不同，请勿套用辅助机的信息。", "按官方步骤让目标机进入 DFU。Mac mini：断开电源，按住电源按钮同时重新接通电源，继续按住最长约 10 秒，直到辅助机 Finder 出现 DFU 窗口。", "先尝试 Finder 的“修复 Mac”（Revive），它不抹掉用户数据。若无效并且所有者已授权清除，再选择“恢复 Mac”（Restore），该操作会抹除目标设备。", "保持双机供电。按目标机的后续提示进行网络激活；T2 机型可能还需从恢复环境安装 macOS。原主账户与组织归属仍需正常解除。"],
                         links: [link("Apple：DFU 修复与恢复步骤", "108900"), link("Apple：查找目标 Mac 的 DFU 端口", "120694")])
        }
    }
}

public struct ResetRecord: Codable, Equatable {
    public var backupExportedAt: Date?
    public var assistantRequestedAt: Date?
    public var assistantOpenedAt: Date?
    public var assistantError: String?
    public var postChecks: [ManualCheck] = [
        .init(id: "setup", title: "已观察到设置助理", instructions: "在目标机抹除后观察设置助理。只到欢迎画面不代表已排除激活锁或企业管理。"),
        .init(id: "activation", title: "联网激活核验", instructions: "连接网络，确认激活流程不再要求原主 Apple 账户；没走到这一步请保留未验证。"),
        .init(id: "organization", title: "远程管理与组织释放核验", instructions: "联网走到相关设置步骤，记录是否出现远程管理；企业来源机器还应保留原组织释放凭证。")
    ]
    public init() {}
    public var unresolvedCount: Int { postChecks.filter { $0.state != .passed || $0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count }
    public var summary: String {
        if postChecks.contains(where: { $0.state == .issue }) { return "操作人记录了交机问题" }
        if postChecks.count == 3 && postChecks.allSatisfy({ $0.state == .passed && !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return "操作人已填写交机核验；不构成自动抹除证明" }
        return "交机尚未核验完成 · 抹除结果未自动验证"
    }
    public var lines: [String] {
        func stamp(_ date: Date?) -> String { date?.formatted(date: .numeric, time: .standard) ?? "未记录" }
        return [summary, "交机包导出：\(stamp(backupExportedAt))", "请求打开系统抹掉助理：\(stamp(assistantRequestedAt))", "系统已接受打开请求：\(stamp(assistantOpenedAt))", "打开入口不表示用户已确认抹除，也不表示抹除完成。"]
            + (assistantError.map { ["入口错误：\($0)"] } ?? [])
            + postChecks.flatMap { ["\($0.title)：\($0.state.title)\($0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? " · 缺少观察记录" : "")", "操作人记录：\($0.note.isEmpty ? "未填写" : $0.note)", "记录时间：\(stamp($0.updatedAt))"] }
    }
}

public enum HandoffPackage {
    public static func export(_ report: InspectionReport, host: ResetHost?, into parent: URL) throws -> URL {
        let directory = parent.appendingPathComponent("MacDetect-交机-\(report.id.uuidString.prefix(8))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        // External FAT / exFAT volumes may not support POSIX permissions.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        do {
            try ReportExporter.json(report).write(to: directory.appendingPathComponent("验机报告.json"), options: .atomic)
            try Data(ReportExporter.html(report).utf8).write(to: directory.appendingPathComponent("验机报告.html"), options: .atomic)
            try PDFExporter.write(report, to: directory.appendingPathComponent("验机报告.pdf"))
            let hardware = host?.matches(report) == true ? host!.hardware : .unknown
            var lines = ["Mac 验机助手 · 交机操作单", "报告编号：\(report.id.uuidString)", "目标机型：\(report.machine.model) · \(report.machine.modelIdentifier)", "目标序列号：\(report.machine.serial)", "请先将整个文件夹复制到 U 盘或另一台电脑；同一台 Mac 的桌面、下载目录及其他内置宗卷均可能随抹除丢失。", "请保存一份验机助手安装包到外部设备。抹除后可重新复制运行，并通过“导入交机 JSON”恢复本记录，继续填写交机核验。", "此操作单不是抹除完成证明。密码仅在 Apple 系统界面输入。"]
            for goal in ResetGoal.allCases {
                let guide = ResetGuide.make(goal: goal, hardware: hardware)
                lines += ["\n\(guide.title)", guide.detail] + guide.steps.enumerated().map { "\($0.offset + 1). \($0.element)" } + guide.links.map { "\($0.title)：\($0.url.absoluteString)" }
            }
            try Data(lines.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("交机操作单.txt"), options: .atomic)
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            return directory
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    /// An import is a historical record, never an authorization or a current host.
    public static func read(_ url: URL) throws -> InspectionReport {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024 else { throw SystemParsers.ParseError.missing("报告超过 4 MiB 上限") }
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1024 * 1024 else { throw SystemParsers.ParseError.missing("报告超过读取上限") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var report = try decoder.decode(InspectionReport.self, from: data)
        guard (1...3).contains(report.schemaVersion), ResetHost.validSerial(report.machine.serial), report.checks.count <= 64, report.manual.count <= 64,
              (report.resetRecord?.postChecks.map(\.id) ?? ["setup", "activation", "organization"]) == ["setup", "activation", "organization"],
              report.resetRecord?.postChecks.allSatisfy({ [.unverified, .passed, .issue].contains($0.state) && $0.note.count <= 4000 }) ?? true,
              Set(report.checks.map(\.id)).count == report.checks.count, Set(report.manual.map(\.id)).count == report.manual.count,
              report.notes.count <= 16000, report.assetTag.count <= 200, report.manual.allSatisfy({ $0.note.count <= 4000 }),
              report.checks.allSatisfy({ $0.title.count <= 256 && $0.summary.count <= 16000 && $0.evidence.count <= 512 && $0.evidence.allSatisfy { $0.count <= 16000 } }) else {
            throw SystemParsers.ParseError.missing("报告格式、身份字段或版本不受支持")
        }
        report.importedFromReportID = report.id; report.id = UUID()
        // Preserve original results; create a separate local record to avoid overwrites.
        return report
    }
}
