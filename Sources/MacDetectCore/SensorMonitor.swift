import Foundation
import Darwin

/// The SMC client stays out of the scanner process: a stalled driver cannot block
/// cancel, thermal safety checks or app shutdown. IPC is one bounded atomic file.
final class SensorMonitor {
    private let child = Process()
    private let directory: URL
    private let snapshotFile: URL
    private let started = ProcessInfo.processInfo.systemUptime
    private var lastPoll: Double = 0
    private var lastDate: Date?
    private(set) var failed = false
    init(executable: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacDetect-sensors-\(UUID().uuidString)")
        snapshotFile = directory.appendingPathComponent("snapshot.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["--monitor-sensors", snapshotFile.path, "--parent-pid", String(getpid())]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice; child.standardInput = FileHandle.nullDevice
        do { try child.run() }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func poll() -> SensorSnapshot? {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPoll >= 0.5 else { return nil }; lastPoll = now
        if !child.isRunning { failed = true }
        guard let size = try? snapshotFile.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 256 * 1024,
              let data = try? Data(contentsOf: snapshotFile), let snapshot = try? JSONDecoder().decode(SensorSnapshot.self, from: data),
              snapshot.temperatures.count <= 256, snapshot.fans.count <= 16,
              snapshot.temperatures.allSatisfy({ $0.value.isFinite && $0.value > 0 && $0.value <= 125 }),
              snapshot.fans.allSatisfy({ $0.value.isFinite && (0...30000).contains($0.value) }),
              (-2...12).contains(Date().timeIntervalSince(snapshot.sampledAt)) else {
            if now - started > 15 { failed = true; stop() }
            return nil
        }
        guard snapshot.sampledAt != lastDate else { return nil }
        lastDate = snapshot.sampledAt
        return snapshot
    }
    func stop() {
        if child.isRunning {
            child.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
    }
    deinit { stop(); try? FileManager.default.removeItem(at: directory) }
}

public enum SensorHelper {
    public static func monitor(destination: URL, parentPID: Int32) throws {
        guard parentPID > 1, getppid() == parentPID else { return }
        let reader = SensorReader()
        let deadline = ProcessInfo.processInfo.systemUptime + 2 * 3600
        while getppid() == parentPID && ProcessInfo.processInfo.systemUptime < deadline {
            let data = try JSONEncoder().encode(reader.sample())
            try data.write(to: destination, options: .atomic)
            Thread.sleep(forTimeInterval: 2)
        }
    }
}
