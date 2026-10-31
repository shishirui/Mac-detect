import Foundation

public enum SystemParsers {
    public static func hardware(_ data: Data) throws -> (MachineInfo, CheckResult) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hardware = (root["SPHardwareDataType"] as? [[String: Any]])?.first,
              let model = hardware["machine_model"] as? String else {
            throw ParseError.missing("硬件配置字段不完整")
        }
        var info = MachineInfo()
        info.modelIdentifier = model
        info.model = hardware["machine_name"] as? String ?? model
        info.chip = hardware["chip_type"] as? String ?? hardware["cpu_type"] as? String ?? "无法读取"
        info.cores = hardware["number_processors"] as? String ?? "无法读取"
        if info.cores.hasPrefix("proc "), let first = info.cores.dropFirst(5).split(separator: ":").first { info.cores = "\(first) 核" }
        info.memory = hardware["physical_memory"] as? String ?? "无法读取"
        info.serial = hardware["serial_number"] as? String ?? "无法读取"
        #if arch(arm64)
        info.architecture = "Apple silicon · arm64"
        #else
        info.architecture = "Intel / Rosetta · x86_64"
        #endif
        let state = hardware["activation_lock_status"] as? String
        let activation: CheckResult
        switch state {
        case "activation_lock_enabled":
            activation = .init("activation", "激活锁状态", .security, status: .warning,
                               summary: "系统报告激活锁已启用，交机前须由原主解除",
                               evidence: ["来源：system_profiler SPHardwareDataType", "卖家需关闭“查找”，并在抹掉后联网完成交机验证。"])
        case "activation_lock_disabled":
            activation = .init("activation", "激活锁状态", .security, status: .passed,
                               summary: "系统报告激活锁已关闭；仍需完成交机激活验证",
                               evidence: ["来源：system_profiler SPHardwareDataType", "此项仅代表当前系统报告，不替代抹掉后的联网激活。"])
        default:
            activation = .init("activation", "激活锁状态", .security, status: .unavailable,
                               summary: "系统未提供可识别的激活锁状态", evidence: ["不把字段缺失解释为无锁。部分旧机型不适用，仍需核实账户与固件启动限制。"])
        }
        return (info, activation)
    }

    public static func storage(_ data: Data) throws -> (CheckResult, String, String) {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw ParseError.missing("磁盘信息不可解析") }
        let size = (root["APFSContainerSize"] as? NSNumber)?.int64Value ?? (root["TotalSize"] as? NSNumber)?.int64Value ?? 0
        let free = (root["APFSContainerFree"] as? NSNumber)?.int64Value ?? (root["FreeSpace"] as? NSNumber)?.int64Value ?? -1
        let smart = (root["SMARTStatus"] as? String ?? "").lowercased()
        let isInternal = root["Internal"] as? Bool
        var evidence = ["来源：diskutil info -plist /", "检测对象：当前启动系统所在磁盘；其他内置盘与外置盘未覆盖。",
                        "SMART：\(smart.isEmpty ? "未提供" : smart)",
                        "APFS 容器 / 卷容量：\(formatBytes(size))；可用空间：\(free >= 0 ? formatBytes(free) : "未知")",
                        "容量为系统可见容器 / 卷容量，并非 SSD 原始标称容量。"]
        if isInternal == false { evidence.append("当前系统从外置磁盘启动，不能据此判断内置 SSD 健康。") }
        let status: CheckStatus
        let summary: String
        if smart == "failing" || smart == "failed" { status = .failed; summary = "系统报告磁盘 SMART 异常，建议暂停收购并复核" }
        else if isInternal != true { status = .unavailable; summary = "未确认检测对象为内置系统磁盘" }
        else if smart == "verified" { status = .passed; summary = "系统磁盘 SMART 基础状态正常；不代表完整寿命检测" }
        else { status = .unavailable; summary = "系统未提供可识别的磁盘健康状态" }
        return (.init("storage", "系统磁盘健康", .storage, status: status, summary: summary, evidence: evidence), formatBytes(size), free >= 0 ? formatBytes(free) : "未知")
    }

    public static func management(_ output: String, exitCode: Int32) -> CheckResult {
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let dep = lines.first { $0.hasPrefix("enrolled via dep:") }
        let mdm = lines.first { $0.hasPrefix("mdm enrollment:") }
        let yes = [dep, mdm].compactMap { $0 }.contains { $0.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces).hasPrefix("yes") }
        let depNo = dep == "enrolled via dep: no"
        let mdmNo = mdm == "mdm enrollment: no"
        let evidence = ["来源：profiles status -type enrollment（只读）", "本机注册状态不能证明 Apple Business / School Manager 云端归属已解除。"]
        if yes { return .init("management", "企业管理状态", .security, status: .warning, summary: "发现设备注册或 MDM 管理迹象，须由原组织解除", evidence: evidence) }
        if exitCode == 0 && depNo && mdmNo { return .init("management", "企业管理状态", .security, status: .passed, summary: "本机未报告 DEP / MDM 注册；云端归属仍须核实", evidence: evidence) }
        return .init("management", "企业管理状态", .security, status: .unavailable, summary: "无法明确读取管理状态，不能判定无企业绑定", evidence: evidence)
    }

    public static func formatBytes(_ count: Int64) -> String {
        guard count > 0 else { return count == 0 ? "0 B" : "未知" }
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .decimal)
    }
    public enum ParseError: LocalizedError {
        case missing(String)
        public var errorDescription: String? { if case .missing(let message) = self { return message }; return nil }
    }
}
