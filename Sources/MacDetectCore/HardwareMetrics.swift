import Foundation
import MacDetectHardware

/// SMART counters are unsigned 128-bit little-endian integers. Keep decimal strings
/// in reports so neither UInt64 overflow nor JSON's floating-point precision loses data.
enum WideCounter {
    static func decimal(_ bytes: ArraySlice<UInt8>, multiplier: Int = 1) -> String {
        var digits = [0]
        for byte in bytes.reversed() {
            var carry = Int(byte)
            for i in digits.indices { let value = digits[i] * 256 + carry; digits[i] = value % 10; carry = value / 10 }
            while carry > 0 { digits.append(carry % 10); carry /= 10 }
        }
        var carry = 0
        for i in digits.indices { let value = digits[i] * multiplier + carry; digits[i] = value % 10; carry = value / 10 }
        while carry > 0 { digits.append(carry % 10); carry /= 10 }
        return digits.reversed().map(String.init).joined()
    }
}

public struct SSDHealth: Codable, Equatable {
    public var disk: String
    public var sampledAt: Date
    public var percentageUsed: Int
    public var availableSpare: Int
    public var spareThreshold: Int
    public var criticalWarning: Int
    public var temperatureCelsius: Double?
    public var dataUnitsWritten: String
    public var writtenBytesUpperBound: String?
    public var powerOnHours: String
    public var powerCycles: String
    public var unsafeShutdowns: String
    public var mediaErrors: String
    public var errorLogEntries: String
    public var enduranceText: String { percentageUsed == 255 ? ">254%" : "\(percentageUsed)%" }
    public var writtenText: String {
        guard let bytes = writtenBytesUpperBound, let amount = Double(bytes) else { return "未上报" }
        return String(format: "约 %.2f TB", amount / 1_000_000_000_000)
    }
    public var check: CheckResult {
        var reasons: [String] = []
        if criticalWarning != 0 { reasons.append(String(format: "设备当前关键告警：0x%02X", criticalWarning)) }
        let labels = ["备用空间低于阈值", "温度超出设备阈值", "可靠性降低", "介质进入只读状态", "易失性存储备份故障", "持久内存区域异常"]
        for bit in 0..<labels.count where criticalWarning & (1 << bit) != 0 { reasons.append(labels[bit]) }
        if availableSpare < spareThreshold { reasons.append("备用空间低于厂家阈值") }
        if percentageUsed >= 100 { reasons.append("厂家估计的额定耐久已消耗完；不等于立即失效，需要复核") }
        if mediaErrors != "0" { reasons.append("存在累计介质 / 数据完整性错误，需结合复测及增长情况核查") }
        let status: CheckStatus = !reasons.isEmpty ? .warning : (writtenBytesUpperBound == nil ? .unavailable : .passed)
        let evidence = [
            "来源：macOS IOKit NVMe SMART；启动卷对应物理盘 \(disk)，控制器级数据。采样：\(sampledAt.formatted(date: .numeric, time: .standard))",
            "额定耐久消耗（厂家估算）：\(enduranceText)；不是还能使用多少年的预测，也不是整机健康评分。",
            "累计主机写入：\(writtenText)；原始 Data Units Written：\(dataUnitsWritten)。",
            "每单位 512,000 字节，向上取整；TB 使用十进制。不含元数据，不等同于 NAND 实际写入。0 表示未上报。",
            "备用空间：\(availableSpare)%；厂家阈值：\(spareThreshold)%；当前关键告警：\(String(format: "0x%02X", criticalWarning))。",
            "SSD 复合温度：\(temperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "未上报或无效")（本次快照）。",
            "通电小时：\(powerOnHours)；通电次数：\(powerCycles)；非正常关机累计：\(unsafeShutdowns)。",
            "累计介质 / 数据完整性错误：\(mediaErrors)；错误日志累计条目：\(errorLogEntries)。",
            "通电、非正常关机和错误日志次数本身不直接证明硬件故障；控制器数据不能证明磁盘未更换或记录未重置。"
        ] + reasons
        return .init("ssdDetail", "SSD 磨损与累计写入", .storage, status: status,
                     summary: !reasons.isEmpty ? "SSD 指标需要复核：" + reasons.joined(separator: "；") : (status == .unavailable ? "耐久数据已读取，但累计写入未上报" : "耐久消耗 \(enduranceText) · 累计写入 \(writtenText)；未见当前 SMART 告警"), evidence: evidence)
    }
    static func parse(_ data: Data, disk: String, date: Date = Date()) throws -> SSDHealth {
        let b = Array(data)
        guard b.count == 512, b.contains(where: { $0 != 0 }), b[3] <= 100, b[4] <= 100 else {
            throw SystemParsers.ParseError.missing("NVMe 健康数据长度或字段无效，不能判为正常")
        }
        func count(_ offset: Int) -> String { WideCounter.decimal(b[offset..<offset+16]) }
        let kelvin = Int(b[1]) | Int(b[2]) << 8
        let celsius = Double(kelvin) - 273.15
        let written = count(48)
        return SSDHealth(disk: disk, sampledAt: date, percentageUsed: Int(b[5]), availableSpare: Int(b[3]), spareThreshold: Int(b[4]), criticalWarning: Int(b[0]),
                         temperatureCelsius: kelvin != 0 && kelvin != 65535 && (-50...200).contains(celsius) ? celsius : nil,
                         dataUnitsWritten: written, writtenBytesUpperBound: written == "0" ? nil : WideCounter.decimal(b[48..<64], multiplier: 512_000),
                         powerOnHours: count(128), powerCycles: count(112), unsafeShutdowns: count(144), mediaErrors: count(160), errorLogEntries: count(176))
    }
}

public struct SSDProbe: Codable {
    public var health: SSDHealth?
    public var error: String?
    public static func read(disk: String) -> SSDProbe {
        var bytes = [UInt8](repeating: 0, count: 512)
        let status = disk.withCString { md_nvme_read_health($0, &bytes, bytes.count) }
        guard status == 0 else { return .init(error: String(format: "NVMe SMART 不可读取（0x%08X）；可能为 SATA、外置桥接、接口不支持或权限限制。未验证不代表故障。", status)) }
        do { return .init(health: try SSDHealth.parse(Data(bytes), disk: disk)) }
        catch { return .init(error: error.localizedDescription) }
    }
}

/// Never pick disk0 by convention: trace the actual boot volume's single physical store.
enum BootDiskResolver {
    static func physicalStore(_ plist: Data) throws -> String {
        guard let root = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any], root["Internal"] as? Bool == true else {
            throw SystemParsers.ParseError.missing("启动盘不是已确认的内置磁盘；不将其他磁盘的寿命当作系统盘结果")
        }
        if let stores = root["APFSPhysicalStores"] as? [[String: Any]] {
            guard stores.count == 1, let store = stores[0]["APFSPhysicalStore"] as? String, validDevice(store) else {
                throw SystemParsers.ParseError.missing("多物理盘 / Fusion Drive 或物理盘映射不明确，需要逐盘复核")
            }
            return store
        }
        guard let device = root["ParentWholeDisk"] as? String, validDevice(device) else {
            throw SystemParsers.ParseError.missing("系统没有提供明确的物理盘映射")
        }
        return device
    }
    static func wholeDisk(_ plist: Data) throws -> String {
        guard let root = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any], root["Internal"] as? Bool == true,
              root["VirtualOrPhysical"] as? String != "Virtual",
              root["SolidState"] as? Bool == true,
              let disk = (root["ParentWholeDisk"] ?? root["DeviceIdentifier"]) as? String,
              disk.range(of: "^disk[0-9]+$", options: .regularExpression) != nil else {
            throw SystemParsers.ParseError.missing("未能确认内置物理盘，不能将逻辑卷作为 NVMe 设备")
        }
        return disk
    }
    static func validDevice(_ value: String) -> Bool { value.range(of: "^disk[0-9]+(s[0-9]+)*$", options: .regularExpression) != nil && value.count < 32 }
}

public struct SensorReading: Codable, Equatable, Identifiable {
    public var key: String
    public var value: Double
    public var id: String { key }
}
public struct SensorSnapshot: Codable, Equatable {
    public var sampledAt = Date()
    public var temperatures: [SensorReading] = []
    public var fans: [SensorReading] = []
    public var fanCount: Int?
    public var thermalState: Int = ProcessInfo.processInfo.thermalState.rawValue
    public var error: String?
}
public struct SensorRange: Codable, Equatable, Identifiable {
    public var key: String
    public var last: Double
    public var minimum: Double
    public var maximum: Double
    public var samples: Int
    public var id: String { key }
}
public struct SensorSession: Codable, Equatable {
    public var latest: SensorSnapshot?
    public var temperatures: [SensorRange] = []
    public var fans: [SensorRange] = []
    public var sampleCount = 0
    public var peakThermalState = 0
    public var interrupted = false
    public var missingTemperatureSamples = 0
    public var missingFanSamples = 0
    public init() {}
    public mutating func add(_ sample: SensorSnapshot) {
        guard latest == nil || sample.sampledAt > latest!.sampledAt else { return }
        latest = sample; sampleCount += 1; peakThermalState = max(peakThermalState, sample.thermalState)
        if sample.temperatures.isEmpty || temperatures.contains(where: { range in !sample.temperatures.contains { $0.key == range.key } }) { missingTemperatureSamples += 1 }
        if sample.fanCount == nil || sample.fans.count != sample.fanCount || fans.contains(where: { range in !sample.fans.contains { $0.key == range.key } }) { missingFanSamples += 1 }
        Self.merge(sample.temperatures, into: &temperatures); Self.merge(sample.fans, into: &fans)
    }
    private static func merge(_ samples: [SensorReading], into ranges: inout [SensorRange]) {
        for sample in samples {
            if let i = ranges.firstIndex(where: { $0.key == sample.key }) {
                ranges[i].last = sample.value; ranges[i].minimum = min(ranges[i].minimum, sample.value)
                ranges[i].maximum = max(ranges[i].maximum, sample.value); ranges[i].samples += 1
            } else { ranges.append(.init(key: sample.key, last: sample.value, minimum: sample.value, maximum: sample.value, samples: 1)) }
        }
        ranges.sort { $0.key < $1.key }
    }
    public static func isKnownFanless(_ machine: MachineInfo) -> Bool {
        // Identified fanless M1/M2/M3/M4 Air models. Unknown models stay unverified.
        ["MacBookAir10,1", "Mac14,2", "Mac14,15", "Mac15,12", "Mac15,13", "Mac16,12", "Mac16,13"].contains(machine.modelIdentifier)
    }
    public func temperatureCheck() -> CheckResult {
        let status: CheckStatus = temperatures.isEmpty ? .unavailable : (interrupted || missingTemperatureSamples > 0 || peakThermalState >= 2 ? .warning : .passed)
        let maximum = temperatures.map(\.maximum).max()
        return .init("temperature", "温度传感器", .system, status: status,
                     summary: temperatures.isEmpty ? "未取得有效 SMC 温度；不能据此判断散热" : "已读取 \(temperatures.count) 个温度通道 · 采样最高 \(String(format: "%.1f", maximum!))°C",
                     evidence: context + ["SMC 通道标识随机型变化；显示原始键名，不将未知通道冒充 CPU 核心温度。", "读到温度只代表采集成功。各机型阈值不同，不用统一摄氏阈值判定故障；负载保护采用系统热压力。", "温度缺失采样：\(missingTemperatureSamples)；期间最高系统热状态：\(Scanner.thermalLabel(peakThermalState))。", "下列列出峰值最高的最多 24 个通道；全部通道统计保存在 JSON 报告的 sensors 字段。"] + temperatures.sorted { $0.maximum == $1.maximum ? $0.key < $1.key : $0.maximum > $1.maximum }.prefix(24).map { "\($0.key)：最后 \(format($0.last))°C · 最低 \(format($0.minimum))°C · 最高 \(format($0.maximum))°C · \($0.samples) 次" })
    }
    public func fanCheck(machine: MachineInfo) -> CheckResult {
        let fanless = Self.isKnownFanless(machine) && (latest?.fanCount ?? 0) == 0 && fans.isEmpty
        let status: CheckStatus = fanless ? .notApplicable : (fans.isEmpty ? .unavailable : (interrupted || missingFanSamples > 0 ? .warning : .passed))
        return .init("fans", "风扇转速", .system, status: status,
                     summary: fanless ? "此机型采用无风扇设计，风扇检查不适用" : (fans.isEmpty ? "未取得风扇转速；不能认定没有风扇或风扇损坏" : "已读取 \(fans.count) 个风扇转速通道"),
                     evidence: context + ["只读 AppleSMC FNum / F?Ac，不改变转速或散热控制策略。", "0 RPM 可能表示停转策略，不能单凭转速判断损坏。需要在负载下观察转速变化、热状态及异响。", fanless ? "依据已知无风扇机型标识：\(machine.modelIdentifier)" : "设备上报风扇数量：\(latest?.fanCount.map(String.init) ?? "无法读取")；缺失采样：\(missingFanSamples)。"] + fans.map { "\($0.key)：最后 \(format($0.last)) RPM · 最低 \(format($0.minimum)) RPM · 最高 \(format($0.maximum)) RPM · \($0.samples) 次" })
    }
    private var context: [String] {
        ["来源：AppleSMC 只读传感器；\(sampleCount) 次采样。标准 / 深度验机负载期间目标间隔约 2 秒，采样间的瞬时峰值可能遗漏。", "最后采样：\(latest?.sampledAt.formatted(date: .numeric, time: .standard) ?? "无")。\(interrupted ? "持续采样中断，历史数据不代表当前值。" : "")"] + (latest?.error.map { [$0] } ?? [])
    }
    private func format(_ value: Double) -> String { String(format: "%.1f", value) }
}

/// Decoder is separate from IOKit so byte order, signed values and invalid samples
/// can be verified without requiring every Mac model on the test host.
enum SMCNumber {
    static func key(_ text: String) -> UInt32 { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    static func name(_ key: UInt32) -> String { String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: key >> $0) }, encoding: .ascii) ?? "????" }
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        let value: Double
        switch (type, bytes.count) {
        case ("flt ", 4): value = Double(Float(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
        case ("sp78", 2): value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case ("fpe2", 2): value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case ("ui8 ", 1): value = Double(bytes[0])
        case ("ui16", 2): value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case ("ui32", 4): value = Double(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        default: return nil
        }
        return value.isFinite ? value : nil
    }
}

/// Used only in an isolated, killable helper process. Never writes SMC keys.
public final class SensorReader {
    private var connection: UInt32 = 0
    private var temperatureKeys: [String] = []
    private var failure: String?
    public init() {
        let status = md_smc_open(&connection)
        guard status == 0 else { failure = String(format: "SMC 接口不可用（0x%08X），可能受机型、系统或权限限制。", status); return }
        guard let count = number("#KEY"), count >= 1, count <= 16384, count.rounded() == count else { failure = "SMC 键目录不可读取或超出支持范围"; return }
        for index in 0..<UInt32(count) {
            var key: UInt32 = 0
            guard md_smc_key_at_index(connection, index, &key) == 0 else { continue }
            let name = SMCNumber.name(key)
            guard name.first == "T", let raw = read(name), ["sp78", "flt "].contains(raw.type) else { continue }
            temperatureKeys.append(name)
            if temperatureKeys.count >= 256 { break }
        }
    }
    deinit { md_smc_close(connection) }
    private func read(_ name: String) -> (type: String, bytes: [UInt8])? {
        var raw = MD_SMCValue()
        guard md_smc_read(connection, SMCNumber.key(name), &raw) == 0, (1...32).contains(raw.size) else { return nil }
        return (SMCNumber.name(raw.data_type), withUnsafeBytes(of: raw.bytes) { Array($0.prefix(Int(raw.size))) })
    }
    private func number(_ name: String) -> Double? {
        guard let raw = read(name) else { return nil }
        return SMCNumber.decode(type: raw.type, bytes: raw.bytes)
    }
    public func sample() -> SensorSnapshot {
        var snapshot = SensorSnapshot(); snapshot.error = failure
        guard connection != 0 else { return snapshot }
        for key in temperatureKeys {
            // Reject inactive / sentinel channels (commonly 0 or 129), not as faults.
            if let value = number(key), value > 0, value <= 125 { snapshot.temperatures.append(.init(key: key, value: value)) }
        }
        if let count = number("FNum"), (0...16).contains(count), count.rounded() == count {
            snapshot.fanCount = Int(count)
            for index in 0..<Int(count) {
                let key = "F\(String(index, radix: 16).uppercased())Ac"
                if let value = number(key), (0...30000).contains(value) { snapshot.fans.append(.init(key: key, value: value)) }
            }
        }
        snapshot.sampledAt = Date()
        return snapshot
    }
}
