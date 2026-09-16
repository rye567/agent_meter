import Foundation
import Darwin
import IOKit

// MARK: - CPU 占用采集（host_statistics64 / host_processor_info tick 差值）

final class CPUSampler {
    private var prevTotal: [Int32] = []
    private var prevCores: [[Int32]] = []
    private let frequencySampler = FrequencySampler()

    func collect() -> CPUSnapshot {
        var snapshot = CPUSnapshot()
        snapshot.chipName = Sysctl.string("machdep.cpu.brand_string") ?? "Mac"

        if let ticks = hostCPULoadInfo() {
            if prevTotal.count == 4 {
                let dUser = ticks[0] - prevTotal[0]
                let dSys = ticks[1] - prevTotal[1]
                let dIdle = ticks[2] - prevTotal[2]
                let dNice = ticks[3] - prevTotal[3]
                let total = Double(dUser + dSys + dIdle + dNice)
                if total > 0 {
                    snapshot.user = pct(Double(dUser + dNice), total)
                    snapshot.system = pct(Double(dSys), total)
                    snapshot.usage = pct(Double(dUser + dSys + dNice), total)
                }
            }
            prevTotal = ticks
        }

        if let cores = perCoreTicks() {
            if prevCores.count == cores.count {
                var perCore: [Double] = []
                perCore.reserveCapacity(cores.count)
                for i in 0..<cores.count {
                    let cur = cores[i], prev = prevCores[i]
                    let total = Double(cur[0] - prev[0] + cur[1] - prev[1]
                                       + cur[2] - prev[2] + cur[3] - prev[3])
                    if total > 0 {
                        let active = Double(cur[0] - prev[0] + cur[1] - prev[1] + cur[3] - prev[3])
                        perCore.append(min(max(active / total * 100.0, 0), 100))
                    } else {
                        perCore.append(0)
                    }
                }
                snapshot.perCore = perCore
            }
            prevCores = cores
        }

        snapshot.temperatureC = Thermal.cpuTemperature()
        let freq = frequencySampler.sample()
        snapshot.frequencyMHz = freq.pMHz
        snapshot.eFrequencyMHz = freq.eMHz
        if snapshot.frequencyMHz == nil, let hz = Sysctl.uint64("hw.cpufrequency"), hz > 0 {
            snapshot.frequencyMHz = Double(hz) / 1_000_000.0
        }
        return snapshot
    }

    private func pct(_ value: Double, _ total: Double) -> Double {
        min(max(value / total * 100.0, 0), 100)
    }

    private func hostCPULoadInfo() -> [Int32]? {
        var stats = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = stats.cpu_ticks
        return [Int32(t.0), Int32(t.1), Int32(t.2), Int32(t.3)]
    }

    private func perCoreTicks() -> [[Int32]]? {
        var numCPU: natural_t = 0
        var cpuInfo: processor_info_array_t? = nil
        var numInfo: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &numCPU, &cpuInfo, &numInfo)
        guard kr == KERN_SUCCESS, let info = cpuInfo else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(numInfo) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        var cores: [[Int32]] = []
        cores.reserveCapacity(Int(numCPU))
        for cpu in 0..<Int(numCPU) {
            let base = cpu * Int(CPU_STATE_MAX)
            cores.append([info[base], info[base + 1], info[base + 2], info[base + 3]])
        }
        return cores
    }
}

// MARK: - 内存采集

enum MemoryInfo {
    static func collect() -> MemorySnapshot {
        var total: Int64 = 0
        if let mem = Sysctl.uint64("hw.memsize") { total = Int64(mem) }

        var used: Int64 = 0, app: Int64 = 0, wired: Int64 = 0, compressed: Int64 = 0
        if let stats = vmStatistics() {
            let ps = Int64(vm_kernel_page_size)
            app = ps * Int64(stats.internal_page_count - stats.purgeable_count)
            wired = ps * Int64(stats.wire_count)
            compressed = ps * Int64(stats.compressor_page_count)
            used = app + wired + compressed
        }
        return MemorySnapshot(
            totalBytes: total, usedBytes: used, appBytes: app,
            wiredBytes: wired, compressedBytes: compressed,
            swapUsedBytes: SwapUsage.usedBytes())
    }

    private static func vmStatistics() -> vm_statistics64_data_t? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return stats
    }
}

// MARK: - 磁盘采集（卷用量 + 进程级 I/O 汇总近似）

final class DiskSampler {
    func collect(processes: [ProcessSample]) -> DiskSnapshot {
        var read: Double = 0
        var write: Double = 0
        for p in processes {
            read += p.diskReadBytesPerSec
            write += p.diskWriteBytesPerSec
        }
        return DiskSnapshot(
            readBytesPerSec: read, writeBytesPerSec: write, volumes: volumes())
    }

    func volumes() -> [VolumeInfo] {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [
                .volumeNameKey, .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
            ],
            options: [.skipHiddenVolumes]) else { return [] }

        var result: [VolumeInfo] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [
                .volumeNameKey, .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
            ]) else { continue }
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            guard total > 0 else { continue }
            result.append(VolumeInfo(
                name: values.volumeName ?? url.lastPathComponent,
                path: url, totalBytes: total, freeBytes: free))
        }
        return result
    }
}

// MARK: - 网络采集（getifaddrs 计数差值，32 位计数器处理回绕）

final class NetworkSampler {
    private var prev: [String: (up: UInt32, down: UInt32)] = [:]
    private var prevTime: Double = 0

    func collect() -> NetworkSnapshot {
        guard let samples = interfaceCounters() else { return NetworkSnapshot() }
        let now = Date().timeIntervalSince1970
        let elapsed = prevTime > 0 ? now - prevTime : 0
        prevTime = now

        var interfaces: [InterfaceTraffic] = []
        var totalUp: Double = 0
        var totalDown: Double = 0

        for (name, up, down) in samples {
            var rateUp: Double = 0
            var rateDown: Double = 0
            if elapsed > 0, let old = prev[name] {
                rateUp = Double(delta(up, old.up)) / elapsed
                rateDown = Double(delta(down, old.down)) / elapsed
            }
            let active = rateUp > 1 || rateDown > 1
            if active {
                totalUp += rateUp
                totalDown += rateDown
                interfaces.append(InterfaceTraffic(
                    name: name, upBytesPerSec: rateUp, downBytesPerSec: rateDown, isActive: true))
            }
            prev[name] = (up, down)
        }
        interfaces.sort {
            ($0.upBytesPerSec + $0.downBytesPerSec) > ($1.upBytesPerSec + $1.downBytesPerSec)
        }
        return NetworkSnapshot(
            interfaces: interfaces,
            upBytesPerSec: totalUp, downBytesPerSec: totalDown)
    }

    private func delta(_ current: UInt32, _ previous: UInt32) -> UInt64 {
        current >= previous
            ? UInt64(current - previous)
            : UInt64(UInt32.max - previous) + UInt64(current) + 1
    }

    private func interfaceCounters() -> [(String, UInt32, UInt32)]? {
        var ifap: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(first) }

        var result: [(String, UInt32, UInt32)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let dataPtr = ifa.ifa_data {
                let data = dataPtr.assumingMemoryBound(to: if_data.self)
                result.append((String(cString: ifa.ifa_name),
                               data.pointee.ifi_obytes, data.pointee.ifi_ibytes))
            }
            ptr = ifa.ifa_next
        }
        return result
    }
}

// MARK: - 进程磁盘 I/O 采集（proc_pid_rusage 差值）

final class ProcessSampler {
    private var prevDiskRead: [pid_t: UInt64] = [:]
    private var prevDiskWrite: [pid_t: UInt64] = [:]
    private var prevTime: Double = 0
    private let selfPID = getpid()

    func collect(interval: Double) -> [ProcessSample] {
        let now = Date().timeIntervalSince1970
        let elapsed = prevTime > 0 ? now - prevTime : 0
        prevTime = now

        var newRead: [pid_t: UInt64] = [:]
        var newWrite: [pid_t: UInt64] = [:]
        var samples: [ProcessSample] = []

        for p in listProcesses() {
            newRead[p.pid] = p.diskRead
            newWrite[p.pid] = p.diskWrite
            var readRate: Double = 0
            var writeRate: Double = 0
            if elapsed > 0 {
                if let old = prevDiskRead[p.pid], p.diskRead > old {
                    readRate = Double(p.diskRead - old) / elapsed
                }
                if let old = prevDiskWrite[p.pid], p.diskWrite > old {
                    writeRate = Double(p.diskWrite - old) / elapsed
                }
            }
            samples.append(ProcessSample(
                pid: p.pid, name: p.name,
                diskReadBytesPerSec: readRate, diskWriteBytesPerSec: writeRate))
        }
        prevDiskRead = newRead
        prevDiskWrite = newWrite
        return samples
    }

    private func listProcesses() -> [(pid: pid_t, name: String, diskRead: UInt64, diskWrite: UInt64)] {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 128)
        count = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        var result: [(pid_t, String, UInt64, UInt64)] = []
        result.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let pid = pids[i]
            guard pid > 0, pid != selfPID else { continue }
            var info = rusage_info_v4()
            // 内核把 rusage 结构体整体写到传入地址（对应 C 用法 (rusage_info_t *)&info）
            let kr = withUnsafeMutableBytes(of: &info) { raw -> Int32 in
                let dest = raw.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self)
                return proc_pid_rusage(pid, RUSAGE_INFO_V4, dest)
            }
            guard kr == 0 else { continue }
            result.append((pid, "", info.ri_diskio_bytesread, info.ri_diskio_byteswritten))
        }
        return result
    }
}

// MARK: - sysctl 辅助

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

enum SwapUsage {
    static func usedBytes() -> Int64 {
        guard let text = Sysctl.string("vm.swapusage") else { return 0 }
        for part in text.split(separator: "  ") {
            let tokens = part.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            if tokens.count == 2, tokens[0].lowercased() == "used",
               let bytes = parseSize(tokens[1]) {
                return bytes
            }
        }
        return 0
    }

    private static func parseSize(_ s: String) -> Int64? {
        guard let unitIndex = s.firstIndex(where: { $0.isLetter }) else { return nil }
        let number = Double(s[..<unitIndex].trimmingCharacters(in: .whitespaces)) ?? 0
        let unit = String(s[unitIndex...]).uppercased()
        let multiplier: Double
        switch unit {
        case "K": multiplier = 1024
        case "M": multiplier = 1024 * 1024
        case "G": multiplier = 1024 * 1024 * 1024
        case "T": multiplier = 1024 * 1024 * 1024 * 1024
        default: multiplier = 1
        }
        return Int64(number * multiplier)
    }
}
