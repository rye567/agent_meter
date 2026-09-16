import Foundation
import Darwin
import IOKit

// MARK: - CPU/SoC 温度（IOHIDEventSystem，Apple Silicon 主路径）
// 新版 macOS 限制了第三方应用直接读 AppleSMC 键，但温度传感器通过
// IOHIDEventSystem 仍然可见：usage page 0xff00 / usage 0x0005
// （Apple vendor temperature sensor），事件类型 15（Temperature）。

@_silgen_name("IOHIDEventSystemClientCreate")
func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> UnsafeMutableRawPointer?
@_silgen_name("IOHIDEventSystemClientSetMatching")
func IOHIDEventSystemClientSetMatching(_ client: UnsafeMutableRawPointer, _ matching: CFDictionary)
@_silgen_name("IOHIDEventSystemClientCopyServices")
func IOHIDEventSystemClientCopyServices(_ client: UnsafeMutableRawPointer) -> CFArray?
@_silgen_name("IOHIDServiceClientCopyProperty")
func IOHIDServiceClientCopyProperty(_ service: UnsafeMutableRawPointer, _ key: CFString) -> CFString?
@_silgen_name("IOHIDServiceClientCopyEvent")
func IOHIDServiceClientCopyEvent(_ service: UnsafeMutableRawPointer, _ type: UInt32, _ timestamp: UInt64, _ options: UInt64) -> UnsafeMutableRawPointer?
@_silgen_name("IOHIDEventGetFloatValue")
func IOHIDEventGetFloatValue(_ event: UnsafeMutableRawPointer, _ field: UInt32) -> Double

enum Thermal {
    private static let eventTypeTemperature: UInt32 = 15

    /// CPU/SoC 温度：取 PMU die 传感器（M 系列 SoC 结温）最大值，
    /// 兼容 M1/M2 时代的 pACC/eACC MTR Temp 命名。无可用传感器时为 nil。
    static func cpuTemperature() -> Double? {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return nil }
        let matching = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 0x0005] as CFDictionary
        IOHIDEventSystemClientSetMatching(client, matching)
        guard let services = IOHIDEventSystemClientCopyServices(client) else { return nil }

        var best: Double? = nil
        let count = CFArrayGetCount(services)
        for i in 0..<count {
            guard let ptr = CFArrayGetValueAtIndex(services, i) else { continue }
            let service = UnsafeMutableRawPointer(mutating: ptr)
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as String? else { continue }
            let isDie = name.hasPrefix("PMU tdie") || name.hasPrefix("PMU2 tdie")
            let isMTR = name.hasPrefix("pACC MTR Temp") || name.hasPrefix("eACC MTR Temp")
            guard isDie || isMTR else { continue }
            guard let event = IOHIDServiceClientCopyEvent(service, eventTypeTemperature, 0, 0) else { continue }
            let value = IOHIDEventGetFloatValue(event, eventTypeTemperature << 16)
            guard value > 15 && value < 120 else { continue }
            if best == nil || value > best! { best = value }
        }
        return best
    }
}
