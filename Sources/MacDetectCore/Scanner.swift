import Foundation

public enum ScanEvent {
    case machine(MachineInfo)
    case result(CheckResult)
    case metrics(SSDHealth?, SensorSession?)
}

public final class Scanner {
    public let token: CancellationToken
    private let executable: String
    private let emit: (ScanEvent) -> Void
    private var report: InspectionReport
    private var monitor: SensorMonitor?
    private var bootDiskInfo: Data?
    public init(mode: InspectionMode, executable: String, token: CancellationToken, report: InspectionReport? = nil, emit: @escaping (ScanEvent) -> Void) {
        self.report = report ?? InspectionReport(mode: mode)
        self.executable = executable; self.token = token; self.emit = emit
    }
    private func publish(_ result: CheckResult) {
        if let index = report.checks.firstIndex(where: { $0.id == result.id }) { report.checks[index] = result }
        emit(.result(result))
    }
    private func perform(_ id: String, _ action: () throws -> CheckResult) {
        guard !token.isCancelled, var template = report.checks.first(where: { $0.id == id }) else { return }
        template.status = .running; template.summary = "正在检测，请稍候"; publish(template)
        let start = ProcessInfo.processInfo.systemUptime
        var result: CheckResult
        do { result = try action() }
        catch {
            result = template; result.status = .unavailable
            result.summary = "检测未能完成，不能据此判断硬件故障"
            result.evidence = [error.localizedDescription]
        }
        result.elapsed = ProcessInfo.processInfo.systemUptime - start
        if token.isCancelled { result.status = .interrupted; result.summary = "用户停止检测，结果不完整" }
        publish(result)
    }
    private func command(_ path: String, _ arguments: [String], timeout: Double = 30) throws -> CommandOutput {
        let output = try ProcessRunner.run(path, arguments, timeout: timeout, cancellation: token)
        if let reason = output.interruption { throw SystemParsers.ParseError.missing(reason) }
        return output
    }
    public func run() -> InspectionReport {
        perform("hardware") {
            let output = try command("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"], timeout: 45)
            guard output.exitCode == 0 else { throw SystemParsers.ParseError.missing("系统信息读取失败（退出码 \(output.exitCode)）") }
            let (machine, activation) = try SystemParsers.hardware(output.data)
            report.machine = machine; emit(.machine(machine)); publish(activation)
            return .init("hardware", "硬件配置", .configuration, status: .passed,
                         summary: "已读取机器配置，请与卖家描述及机身信息核对",
                         evidence: ["来源：system_profiler SPHardwareDataType", "\(machine.model) · \(machine.modelIdentifier)", "\(machine.chip) · \(machine.cores) · 内存 \(machine.memory)", "系统提供的信息不证明机器从未维修。"])
        }
        if !token.isCancelled && report.checks.first(where: { $0.id == "activation" })?.status == .pending {
            publish(.init("activation", "激活锁状态", .security, status: .unavailable, summary: "硬件信息读取失败，激活锁状态未验证"))
        }
        perform("storage") {
            let output = try command("/usr/sbin/diskutil", ["info", "-plist", "/"])
            guard output.exitCode == 0 else { throw SystemParsers.ParseError.missing("磁盘信息读取失败") }
            bootDiskInfo = output.data
            let (result, size, free) = try SystemParsers.storage(output.data)
            report.machine.storage = size; report.machine.freeStorage = free; emit(.machine(report.machine))
            return result
        }
        perform("ssdDetail") {
            guard let bootDiskInfo else { throw SystemParsers.ParseError.missing("没有启动卷信息，无法选择物理 SSD") }
            let store = try BootDiskResolver.physicalStore(bootDiskInfo)
            let info = try command("/usr/sbin/diskutil", ["info", "-plist", store])
            guard info.exitCode == 0 else { throw SystemParsers.ParseError.missing("物理盘信息读取失败") }
            let disk = try BootDiskResolver.wholeDisk(info.data)
            let output = try command(executable, ["--probe-nvme", disk], timeout: 12)
            guard output.exitCode == 0 else { throw SystemParsers.ParseError.missing("SSD 采集进程未能完成") }
            let probe = try JSONDecoder().decode(SSDProbe.self, from: output.data)
            guard let health = probe.health else { throw SystemParsers.ParseError.missing(probe.error ?? "SSD 数据不可用") }
            report.ssdHealth = health; emit(.metrics(report.ssdHealth, report.sensors))
            return health.check
        }
        perform("management") {
            let output = try command("/usr/bin/profiles", ["status", "-type", "enrollment"])
            return SystemParsers.management(output.text, exitCode: output.exitCode)
        }
        perform("panic") { try crashRecords() }
        perform("thermal") {
            let state = ProcessInfo.processInfo.thermalState
            let label = Self.thermalLabel(state.rawValue)
            return .init("thermal", "系统热状态", .system, status: state.rawValue >= 2 ? .warning : .passed,
                         summary: "检测时系统热状态：\(label)",
                         evidence: ["来源：ProcessInfo.thermalState；这是系统热压力等级，不是摄氏温度。", "摄氏温度及风扇数据见独立检测项。单次正常不能证明持续负载下散热正常。"])
        }
        perform("temperature") {
            let output = try command(executable, ["--probe-sensors"], timeout: 15)
            guard output.exitCode == 0 else { throw SystemParsers.ParseError.missing("传感器采集进程未能完成") }
            let sample = try JSONDecoder().decode(SensorSnapshot.self, from: output.data)
            var session = SensorSession(); session.add(sample); report.sensors = session
            emit(.metrics(report.ssdHealth, report.sensors))
            return session.temperatureCheck()
        }
        perform("fans") { (report.sensors ?? SensorSession()).fanCheck(machine: report.machine) }
        if report.mode != .quick && !token.isCancelled {
            do { monitor = try SensorMonitor(executable: executable) }
            catch { report.sensors = report.sensors ?? SensorSession(); report.sensors?.interrupted = true }
        }
        defer { monitor?.stop(); monitor = nil }
        for id in ["cpu", "memory", "gpu", "disk"] {
            guard !token.isCancelled else { break }
            if report.mode == .quick {
                var result = report.checks.first { $0.id == id }!
                result.status = .skipped; result.summary = "快速筛查不运行此项，请选择标准或深度验机"
                publish(result)
            } else {
                perform(id) { try runWorker(id) }
            }
        }
        if report.mode != .quick && report.sensors != nil {
            collectSensors()
            if monitor?.failed == true || token.isCancelled { report.sensors?.interrupted = true }
            publish(report.sensors!.temperatureCheck()); publish(report.sensors!.fanCheck(machine: report.machine))
            emit(.metrics(report.ssdHealth, report.sensors))
        }
        for var result in report.checks where result.status == .pending || result.status == .running {
            result.status = token.isCancelled ? .interrupted : .unavailable
            result.summary = token.isCancelled ? "检测已停止，此项未完成" : "此项未能完成"
            publish(result)
        }
        report.wasCancelled = token.isCancelled
        report.finishedAt = Date()
        return report
    }
    private func collectSensors() {
        guard let monitor else { return }
        let sample = monitor.poll()
        guard sample != nil || (monitor.failed && report.sensors?.interrupted != true) else { return }
        report.sensors = report.sensors ?? SensorSession()
        if let sample { report.sensors?.add(sample) }
        if monitor.failed { report.sensors?.interrupted = true }
        emit(.metrics(report.ssdHealth, report.sensors))
        publish(report.sensors!.temperatureCheck()); publish(report.sensors!.fanCheck(machine: report.machine))
    }
    private func runWorker(_ id: String) throws -> CheckResult {
        let seconds: Double
        switch id { case "cpu": seconds = report.mode.cpuSeconds; case "memory": seconds = report.mode.memorySeconds; case "gpu": seconds = report.mode.gpuSeconds; default: seconds = 180 }
        var arguments = ["--worker", id, "--seconds", String(seconds)]
        var directory: URL?
        if id == "disk" {
            let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let root = cache.appendingPathComponent("MacDetect/Tests", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let location = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            directory = location
            arguments += ["--directory", location.path, "--mib", String(report.mode.diskMiB)]
        }
        defer { if let directory { try? FileManager.default.removeItem(at: directory) } }
        if id == "memory" { arguments += ["--mib", "256"] }
        let output = try ProcessRunner.run(executable, arguments, timeout: seconds + 30, cancellation: token, watchSafety: true, onTick: { self.collectSensors() })
        var result = report.checks.first { $0.id == id }!
        if let reason = output.interruption {
            result.status = token.isCancelled ? .interrupted : .warning
            result.summary = reason
            result.evidence = ["测试未完整完成，不能计为通过。", "期间最高系统热状态：\(Self.thermalLabel(output.thermalPeak))"]
            return result
        }
        guard output.exitCode == 0, let outcome = try? JSONDecoder().decode(WorkerOutcome.self, from: output.data),
              [.passed, .failed, .unavailable, .warning, .interrupted].contains(outcome.status) else {
            result.status = .unavailable; result.summary = "检测进程未返回有效结果，请复测"
            result.evidence = ["进程退出码：\(output.exitCode)", "进程异常不直接等同于硬件故障。"]
            return result
        }
        result.status = outcome.status; result.summary = outcome.summary
        result.evidence = outcome.evidence + ["期间最高系统热状态：\(Self.thermalLabel(output.thermalPeak))"]
        return result
    }
    private func crashRecords() throws -> CheckResult {
        let directory = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var inaccessible = false
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { _, _ in inaccessible = true; return true }) else {
            throw SystemParsers.ParseError.missing("无法访问系统诊断记录目录")
        }
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        var dates: [Date] = []
        var visited = 0
        for case let file as URL in enumerator {
            if token.isCancelled { break }
            visited += 1
            if visited > 10000 { inaccessible = true; break }
            let values = try? file.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if enumerator.level > 2 { enumerator.skipDescendants(); continue }
            let name = file.lastPathComponent.lowercased()
            let isPanic = name.hasSuffix(".panic") || (name.hasSuffix(".ips") && (name.hasPrefix("panic-full") || name.hasPrefix("kernel")))
            guard isPanic, values?.isRegularFile == true, let date = values?.contentModificationDate, date >= cutoff else { continue }
            dates.append(date)
        }
        let status: CheckStatus = !dates.isEmpty ? .warning : (inaccessible ? .unavailable : .passed)
        let summary = !dates.isEmpty ? "发现 \(dates.count) 份近期疑似内核崩溃记录，需要复核原因" : (inaccessible ? "部分诊断记录无法访问，无法完整检查" : "可访问目录中未发现近 30 天内核崩溃文件")
        return .init("panic", "近期内核崩溃记录", .system, status: status, summary: summary,
                     evidence: ["按文件名和修改时间筛查 /Library/Logs/DiagnosticReports，不读取个人日志正文。", "时间范围：近 30 天。文件时间不一定是故障发生时间。", "日志缺失或清空不能证明无故障；崩溃也可能由软件、驱动或外设引起。"] + dates.sorted().suffix(8).map { "记录修改时间：\($0.formatted(date: .numeric, time: .shortened))" })
    }
    public static func thermalLabel(_ value: Int) -> String {
        switch value { case 0: return "正常"; case 1: return "轻度升高"; case 2: return "严重"; case 3: return "临界"; default: return "未知" }
    }
}
