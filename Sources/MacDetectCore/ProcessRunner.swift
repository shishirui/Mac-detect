import Foundation
import Darwin

public struct CommandOutput {
    public var data: Data
    public var exitCode: Int32
    public var interruption: String?
    public var thermalPeak: Int = 0
    public var text: String { String(data: data, encoding: .utf8) ?? "" }
}

private final class PressureSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var active: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// No shell, bounded output, monotonic deadlines, and a kill fallback for a stuck child.
public enum ProcessRunner {
    public static func run(_ executable: String, _ arguments: [String], timeout: Double = 30,
                           cancellation: CancellationToken, watchSafety: Bool = false) throws -> CommandOutput {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacDetect-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdout = directory.appendingPathComponent("stdout")
        let stderr = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdout.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: stderr.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let outHandle = try FileHandle(forWritingTo: stdout)
        let errHandle = try FileHandle(forWritingTo: stderr)
        defer { try? outHandle.close(); try? errHandle.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"; environment["LANG"] = "C"
        child.environment = environment
        child.standardOutput = outHandle; child.standardError = errHandle
        child.standardInput = FileHandle.nullDevice
        if cancellation.isCancelled { return .init(data: Data(), exitCode: -1, interruption: "用户已停止检测") }
        let pressure = PressureSignal()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { pressure.set() }
        source.resume()
        defer { source.cancel() }
        try child.run()
        let start = ProcessInfo.processInfo.systemUptime
        var reason: String?
        var peak = 0
        while child.isRunning {
            peak = max(peak, ProcessInfo.processInfo.thermalState.rawValue)
            if cancellation.isCancelled { reason = "用户已停止检测" }
            else if ProcessInfo.processInfo.systemUptime - start > timeout { reason = "检测超时，未取得完整结果" }
            else if watchSafety && peak >= ProcessInfo.ThermalState.serious.rawValue { reason = "系统热状态升高，已停止负载，请冷却后复测" }
            else if watchSafety && pressure.active { reason = "系统内存压力升高，已停止负载，请关闭其他应用后复测" }
            if let size = try? stdout.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 8 * 1024 * 1024 { reason = "检测输出超出上限" }
            if let size = try? stderr.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1024 * 1024 { reason = "检测错误输出超出上限" }
            if reason != nil {
                child.terminate()
                let until = ProcessInfo.processInfo.systemUptime + 0.5
                while child.isRunning && ProcessInfo.processInfo.systemUptime < until { Thread.sleep(forTimeInterval: 0.02) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
        child.waitUntilExit()
        let readHandle = try FileHandle(forReadingFrom: stdout)
        defer { try? readHandle.close() }
        let data = try readHandle.read(upToCount: 8 * 1024 * 1024) ?? Data()
        return .init(data: data, exitCode: child.terminationStatus, interruption: reason, thermalPeak: peak)
    }
}
