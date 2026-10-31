import Foundation
import Darwin
import CryptoKit
import Metal

private final class CPUAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var mismatch = false
    func add(_ batches: Int, failed: Bool) { lock.lock(); count += batches; mismatch = mismatch || failed; lock.unlock() }
    var snapshot: (Int, Bool) { lock.lock(); defer { lock.unlock() }; return (count, mismatch) }
}

public enum Workers {
    @inline(never) public static func cpuVector(seed: UInt64 = 0x123456789abcdef0) -> UInt64 {
        var x = seed
        for _ in 0..<65_536 { x ^= x << 13; x ^= x >> 7; x ^= x << 17 }
        return x
    }
    public static func cpu(seconds: Double, parallelism: Int? = nil) -> WorkerOutcome {
        let start = ProcessInfo.processInfo.systemUptime
        let end = start + max(0.05, min(seconds, 3600))
        let threads = max(1, min(parallelism ?? ProcessInfo.processInfo.activeProcessorCount, 8))
        let result = CPUAccumulator()
        let expected: [UInt64] = [0xd1b04aa9e63ddb2b, 0xe715d2e7888a1758, 0x7faff56f6256bd5a, 0x490a6d210ce17129, 0x9be29ad6ee77f026, 0xad47029880c03c55, 0x35fd25106a1c9657, 0x0358bd5e04ab5a24]
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            var batches = 0
            var failed = false
            repeat {
                let index = batches & 7
                let value = cpuVector(seed: 0x123456789abcdef0 &+ UInt64(index))
                if value != expected[index] { failed = true; break }
                batches += 1
            } while ProcessInfo.processInfo.systemUptime < end
            result.add(batches, failed: failed)
        }
        let (batches, failed) = result.snapshot
        let evidence = ["\(threads) 个工作线程；完成 \(batches) 轮固定向量整数运算。", "实际耗时：\(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - start)) 秒。", "每轮与独立预计算的 64 位参考值核对；未覆盖全部 CPU 指令与硬件功能。"]
        return .init(failed ? .failed : .passed, failed ? "CPU 运算结果与参考值不一致，请重复检测并核实" : "本次 CPU 运算结果校验通过", evidence)
    }

    public static func memory(seconds: Double, mebibytes: Int) -> WorkerOutcome {
        let bytes = max(1, min(mebibytes, 512)) * 1024 * 1024
        guard let raw = malloc(bytes) else { return .init(.unavailable, "无法分配测试内存，请关闭其他应用后重试") }
        defer { free(raw) }
        let count = bytes / MemoryLayout<UInt64>.size
        let pointer = raw.bindMemory(to: UInt64.self, capacity: count)
        let start = ProcessInfo.processInfo.systemUptime
        let end = start + max(0.05, min(seconds, 3600))
        let patterns: [UInt64] = [0, .max, 0xAAAAAAAAAAAAAAAA, 0x5555555555555555]
        var completed = 0
        repeat {
            for pattern in patterns {
                for index in 0..<count { pointer[index] = UInt64(index) &* 0x9e3779b97f4a7c15 ^ pattern }
                for index in 0..<count {
                    if pointer[index] != (UInt64(index) &* 0x9e3779b97f4a7c15 ^ pattern) {
                        return .init(.failed, "测试内存的数据校验不一致，建议停止收购并复测", ["测试分配：\(bytes / 1024 / 1024) MiB；偏移：\(index * 8) 字节。"])
                    }
                }
                completed += 1
                if ProcessInfo.processInfo.systemUptime >= end { break }
            }
        } while ProcessInfo.processInfo.systemUptime < end
        return .init(.passed, "本次分配内存的读写校验通过", ["测试分配：\(bytes / 1024 / 1024) MiB；完成 \(completed) 轮写入及全量读回。", "实际耗时：\(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - start)) 秒。", "仅测试应用可分配的虚拟内存，可能涉及系统分页；不代表完整物理内存检测。", "未锁定全部物理内存；请配合 Apple 官方诊断。"])
    }

    private static func gpuReference(index: UInt32, seed: UInt32) -> UInt32 {
        var value = index ^ seed
        for step: UInt32 in 0..<64 { value ^= value << 13; value ^= value >> 17; value ^= value << 5; value &+= step }
        return value
    }

    public static func gpu(seconds: Double) -> WorkerOutcome {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            return .init(.unavailable, "当前环境无法创建 Metal GPU 检测任务")
        }
        let shader = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void verify(device uint *output [[buffer(0)]], constant uint &seed [[buffer(1)]], uint index [[thread_position_in_grid]]) {
            uint value = index ^ seed;
            for (uint step = 0; step < 64; ++step) { value ^= value << 13; value ^= value >> 17; value ^= value << 5; value += step; }
            output[index] = value;
        }
        """
        do {
            let library = try device.makeLibrary(source: shader, options: nil)
            guard let function = library.makeFunction(name: "verify") else { return .init(.unavailable, "无法创建 GPU 校验函数") }
            let pipeline = try device.makeComputePipelineState(function: function)
            let count = 262_144
            guard let buffer = device.makeBuffer(length: count * 4, options: .storageModeShared) else { return .init(.unavailable, "无法分配 GPU 测试缓冲区") }
            let start = ProcessInfo.processInfo.systemUptime
            let end = start + max(0.05, min(seconds, 3600))
            var rounds: UInt32 = 0
            repeat {
                guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                    return .init(.unavailable, "无法创建 GPU 命令")
                }
                var seed: UInt32 = rounds &+ 0x12345678
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(buffer, offset: 0, index: 0)
                encoder.setBytes(&seed, length: 4, index: 1)
                let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
                encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
                encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
                if command.status != .completed { return .init(.warning, "GPU 任务未完成，请关闭其他负载后复测", ["Metal 错误：\(command.error?.localizedDescription ?? "未知")", "驱动或系统原因也可能导致任务失败，不能直接判定 GPU 损坏。"] ) }
                let values = buffer.contents().bindMemory(to: UInt32.self, capacity: count)
                // Sample while loading the GPU, then verify the entire final buffer.
                // Checking every element on the CPU each round would turn this into a CPU-bound test.
                let finalRound = ProcessInfo.processInfo.systemUptime >= end
                let indices = finalRound ? Array(0..<count) : Array(stride(from: Int(seed % 257), to: count, by: 257)) + [0, count - 1]
                for index in indices {
                    if values[index] != gpuReference(index: UInt32(index), seed: seed) {
                        return .init(.failed, "GPU 计算结果与 CPU 参考值不一致", ["设备：\(device.name)；轮次：\(rounds + 1)；索引：\(index)。", "请复测并配合官方诊断。"])
                    }
                }
                rounds &+= 1
                if finalRound { break }
            } while true
            return .init(.passed, "本次 Metal GPU 计算及读回校验通过", ["GPU：\(device.name)", "完成 \(rounds) 轮，每轮抽查约 1,020 个结果，最后一轮全量校验 \(count) 个结果。", "实际耗时：\(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - start)) 秒。", "只覆盖默认 Metal GPU；不覆盖所有 GPU、图形指令、视频编解码和显示接口。"])
        } catch { return .init(.unavailable, "无法准备 GPU 检测", [error.localizedDescription]) }
    }

    public static func disk(directory: URL, mebibytes: Int) -> WorkerOutcome {
        let amount = max(1, min(mebibytes, 1024))
        let fm = FileManager.default
        var descriptor: Int32 = -1
        let file = directory.appendingPathComponent("readback-\(UUID().uuidString).bin")
        defer {
            if descriptor >= 0 { close(descriptor); try? fm.removeItem(at: file) }
        }
        do {
            let resource = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeIsInternalKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard resource.isDirectory == true, resource.isSymbolicLink != true else { return .init(.unavailable, "测试目录不可用") }
            guard let available = resource.volumeAvailableCapacity, Int64(available) >= Int64(amount + 2048) * 1024 * 1024 else {
                return .init(.unavailable, "磁盘剩余空间不足，测试至少保留 2 GiB 空间")
            }
            // O_EXCL + O_NOFOLLOW: never overwrite a pre-existing file or follow a final symlink.
            descriptor = open(file.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { return .init(.unavailable, "无法创建独占测试文件", ["系统错误码：\(errno)"]) }
            let uncached = fcntl(descriptor, F_NOCACHE, 1) == 0
            var hashes: [Data] = []
            var block = [UInt64](repeating: 0, count: 1024 * 1024 / 8)
            let writeStart = ProcessInfo.processInfo.systemUptime
            for blockIndex in 0..<amount {
                var value = UInt64(blockIndex + 1) &* 0x9e3779b97f4a7c15
                for index in block.indices { value ^= value << 13; value ^= value >> 7; value ^= value << 17; block[index] = value }
                try block.withUnsafeBytes { raw in
                    hashes.append(Data(SHA256.hash(data: Data(raw))))
                    var offset = 0
                    while offset < raw.count {
                        let written = write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw IOFailure.operation(errno) }
                        offset += written
                    }
                }
            }
            guard fsync(descriptor) == 0 else { throw IOFailure.operation(errno) }
            let writeSeconds = max(0.001, ProcessInfo.processInfo.systemUptime - writeStart)
            guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw IOFailure.operation(errno) }
            let readStart = ProcessInfo.processInfo.systemUptime
            for blockIndex in 0..<amount {
                let digest: Data = try block.withUnsafeMutableBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let received = read(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if received < 0 && errno == EINTR { continue }
                        guard received > 0 else { throw IOFailure.operation(received == 0 ? EIO : errno) }
                        offset += received
                    }
                    return Data(SHA256.hash(data: Data(raw)))
                }
                if digest != hashes[blockIndex] { return .init(.failed, "磁盘写入与读回数据不一致，请复测", ["失败位置：第 \(blockIndex + 1) MiB。", "只测试独立临时文件，未覆盖整盘。"] ) }
            }
            let readSeconds = max(0.001, ProcessInfo.processInfo.systemUptime - readStart)
            let internalText = resource.volumeIsInternal == true ? "测试目录所在卷报告为内置存储。" : "未确认测试目录位于内置存储，不能据此判断内置 SSD。"
            return .init(resource.volumeIsInternal == true ? .passed : .warning, "\(amount) MiB 临时文件写入与 SHA-256 读回校验通过", [internalText, "本次只操作独占临时文件，正常完成后清理。", "写入约 \(Int(Double(amount) / writeSeconds)) MiB/s；读取约 \(Int(Double(amount) / readSeconds)) MiB/s。", "以上吞吐包含数据生成及校验开销，受缓存、后台负载影响，不作为硬件故障阈值。", uncached ? "已请求关闭文件缓存；执行 fsync 后读回。" : "系统未接受关闭文件缓存，结果可能受缓存影响。", "不能保证掉电持久性、所有存储区域或 SSD 剩余寿命。"])
        } catch { return .init(.warning, "磁盘读写测试未完整完成，需要复核", [error.localizedDescription, "空间、权限、文件系统或硬件均可能影响测试；不直接判为硬件损坏。"]) }
    }
    private enum IOFailure: LocalizedError {
        case operation(Int32)
        var errorDescription: String? { if case .operation(let code) = self { return "文件 I/O 失败，系统错误码：\(code)" }; return nil }
    }
}
