import Foundation

// MARK: - 系统监控快照模型（移植自 istats 项目）

struct CPUSnapshot {
    var usage: Double = 0             // 0-100
    var user: Double = 0
    var system: Double = 0
    var perCore: [Double] = []        // 每核 0-100
    var temperatureC: Double?         // HID 温度传感器（PMU die）
    var frequencyMHz: Double?         // P 核加权频率（估算）
    var eFrequencyMHz: Double?        // E 核加权频率（估算）
    var chipName: String = ""
}

struct MemorySnapshot {
    var totalBytes: Int64 = 0
    var usedBytes: Int64 = 0
    var appBytes: Int64 = 0
    var wiredBytes: Int64 = 0
    var compressedBytes: Int64 = 0
    var swapUsedBytes: Int64 = 0
}

struct VolumeInfo: Identifiable {
    var id: String { path.path }
    var name: String
    var path: URL
    var totalBytes: Int64
    var freeBytes: Int64
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(totalBytes - freeBytes) / Double(totalBytes)
    }
}

struct DiskSnapshot {
    var readBytesPerSec: Double = 0   // 各进程磁盘 I/O 汇总（近似）
    var writeBytesPerSec: Double = 0
    var volumes: [VolumeInfo] = []
}

struct NetworkSnapshot {
    var interfaces: [InterfaceTraffic] = []
    var upBytesPerSec: Double = 0
    var downBytesPerSec: Double = 0
}

struct InterfaceTraffic: Identifiable {
    var id: String { name }
    var name: String
    var upBytesPerSec: Double
    var downBytesPerSec: Double
    var isActive: Bool
}

struct ProcessSample {
    var pid: pid_t
    var name: String
    var diskReadBytesPerSec: Double
    var diskWriteBytesPerSec: Double
}

/// 滚动历史序列（波浪图数据），最多保留 capacity 个采样点
struct HistoryData {
    static let capacity = 60

    var cpu: [Double] = []       // 0-100
    var memory: [Double] = []    // 0-100
    var diskRead: [Double] = []  // B/s
    var diskWrite: [Double] = []
    var netUp: [Double] = []
    var netDown: [Double] = []

    mutating func append(cpu: Double, memory: Double,
                         diskRead: Double, diskWrite: Double,
                         netUp: Double, netDown: Double) {
        func push(_ array: inout [Double], _ value: Double) {
            array.append(value)
            if array.count > Self.capacity {
                array.removeFirst(array.count - Self.capacity)
            }
        }
        push(&self.cpu, cpu)
        push(&self.memory, memory)
        push(&self.diskRead, diskRead)
        push(&self.diskWrite, diskWrite)
        push(&self.netUp, netUp)
        push(&self.netDown, netDown)
    }
}

struct SystemSnapshot {
    var cpu: CPUSnapshot = CPUSnapshot()
    var memory: MemorySnapshot = MemorySnapshot()
    var disk: DiskSnapshot = DiskSnapshot()
    var network: NetworkSnapshot = NetworkSnapshot()
    var history = HistoryData()
}

// MARK: - 单元格式化

enum SysFormat {
    static func bytes(_ value: Int64, decimals: Int = 1) -> String {
        let units: [(Double, String)] = [
            (1_125_899_906_842_624, "PB"), (1_099_511_627_776, "TB"),
            (1_073_741_824, "GB"), (1_048_576, "MB"), (1_024, "KB"),
        ]
        for (factor, unit) in units where abs(Double(value)) >= factor {
            return String(format: "%.\(decimals)f %@", Double(value) / factor, unit)
        }
        return "\(value) B"
    }

    static func bytes(_ value: Double) -> String {
        bytes(Int64(value))
    }

    static func speed(_ bytesPerSec: Double) -> String {
        guard bytesPerSec > 0.5 else { return "0 KB/s" }
        return bytes(bytesPerSec) + "/s"
    }

    static func percent(_ value: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", value)
    }

    static func temperature(_ celsius: Double) -> String {
        String(format: "%.0f°C", celsius)
    }

    static func frequency(_ mhz: Double) -> String {
        mhz >= 1000 ? String(format: "%.2f GHz", mhz / 1000) : String(format: "%.0f MHz", mhz)
    }
}
