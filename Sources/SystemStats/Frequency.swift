import Foundation
import Darwin

// MARK: - Apple Silicon CPU 频率（IOReport 性能状态驻留加权估算）
// IOReport "CPU Stats" 组的 "CPU Core/Complex Performance States" 子组：
// 每个 CPU/集群一个通道，通道内是各性能档位的驻留时间。档位名形如
// "V2P17"，P 后缀数字越大频率越高，IDLE 表示空闲。
// 符号通过 dlsym 从 /usr/lib/libIOReport.dylib 加载（共享缓存库）。

final class FrequencySampler {
    private typealias CopyChannelsInGroup = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias MergeChannels = @convention(c) (CFMutableDictionary, CFDictionary, UnsafeRawPointer?) -> Void
    private typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFDictionary?) -> UnsafeMutableRawPointer?
    private typealias CreateSamples = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, CFDictionary?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFDictionary?) -> Unmanaged<CFDictionary>?
    private typealias ChannelGetName = @convention(c) (CFDictionary) -> CFString?
    private typealias StateGetCount = @convention(c) (CFDictionary) -> Int
    private typealias StateGetName = @convention(c) (CFDictionary, Int) -> CFString?
    private typealias StateGetResidency = @convention(c) (CFDictionary, Int) -> UInt64

    private var subscription: UnsafeMutableRawPointer?
    private var channels: CFMutableDictionary?
    private var prevSamples: CFDictionary?
    private var createSamples: CreateSamples?
    private var createDelta: CreateSamplesDelta?
    private var chName: ChannelGetName?
    private var stCount: StateGetCount?
    private var stName: StateGetName?
    private var stRes: StateGetResidency?
    private var failed = false

    // 频率表（MHz）：精确映射表未公开，按 M4 实测范围线性插值估算
    private let pMin = 744.0, pMax = 4410.0
    private let eMin = 744.0, eMax = 2604.0

    func sample() -> (pMHz: Double?, eMHz: Double?) {
        if subscription == nil && !failed { setup() }
        guard let sub = subscription, let channels = channels,
              let createSamples = createSamples,
              let createDelta = createDelta else { return (nil, nil) }

        let current = createSamples(sub, channels, nil)?.takeRetainedValue()
        defer { prevSamples = current }
        guard let previous = prevSamples, let current = current,
              let delta = createDelta(previous, current, nil)?.takeRetainedValue(),
              let array = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return (nil, nil) }

        var pResult: Double?
        var eResult: Double?
        for channel in array {
            let subGroup = channel["IOReportSubGroupName"] as? String ?? ""
            guard subGroup == "CPU Complex Performance States" else { continue }
            let name = (chName?(channel) as String?) ?? ""
            let isP = name.hasPrefix("PCPU")
            let isE = name.hasPrefix("ECPU")
            guard isP || isE else { continue }

            let count = stCount?(channel) ?? 0
            var totalResidency: UInt64 = 0
            var weighted: Double = 0
            var idxMax = 0.0
            for i in 0..<count {
                let stateName = (stName?(channel, i) as String?) ?? ""
                if stateName == "IDLE" || stateName == "DOWN" || stateName == "OFF" { continue }
                if let index = perfIndex(stateName) { idxMax = max(idxMax, Double(index)) }
            }
            for i in 0..<count {
                let stateName = (stName?(channel, i) as String?) ?? ""
                if stateName == "IDLE" || stateName == "DOWN" || stateName == "OFF" { continue }
                guard let index = perfIndex(stateName) else { continue }
                let residency = stRes?(channel, i) ?? 0
                guard residency > 0 else { continue }
                totalResidency += residency
                let lo = isP ? pMin : eMin
                let hi = isP ? pMax : eMax
                let freq = lo + (hi - lo) * (idxMax > 0 ? Double(index) / idxMax : 0)
                weighted += Double(residency) * freq
            }
            guard totalResidency > 0 else { continue }
            let avg = weighted / Double(totalResidency)
            if isP { pResult = avg } else { eResult = avg }
        }
        return (pResult, eResult)
    }

    /// "V2P17" → 17（P 后缀档位号）
    private func perfIndex(_ stateName: String) -> Int? {
        guard let pIndex = stateName.lastIndex(of: "P"),
              pIndex < stateName.index(before: stateName.endIndex) else { return nil }
        return Int(stateName[stateName.index(after: pIndex)...])
    }

    private func setup() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else {
            failed = true
            return
        }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        guard let copyCh = sym("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
              let mergeCh = sym("IOReportMergeChannels", MergeChannels.self),
              let createSub = sym("IOReportCreateSubscription", CreateSubscription.self),
              let createSamples = sym("IOReportCreateSamples", CreateSamples.self),
              let createDelta = sym("IOReportCreateSamplesDelta", CreateSamplesDelta.self),
              let chName = sym("IOReportChannelGetChannelName", ChannelGetName.self),
              let stCount = sym("IOReportStateGetCount", StateGetCount.self),
              let stName = sym("IOReportStateGetNameForIndex", StateGetName.self),
              let stRes = sym("IOReportStateGetResidency", StateGetResidency.self) else {
            failed = true
            return
        }
        self.createSamples = createSamples
        self.createDelta = createDelta
        self.chName = chName
        self.stCount = stCount
        self.stName = stName
        self.stRes = stRes

        guard let channels = copyCh("CPU Stats" as CFString, "CPU Core Performance States" as CFString, 0, 0, 0)?.takeRetainedValue() else {
            failed = true
            return
        }
        if let complex = copyCh("CPU Stats" as CFString, "CPU Complex Performance States" as CFString, 0, 0, 0)?.takeRetainedValue() {
            mergeCh(channels, complex, nil)
        }
        var resolved: Unmanaged<CFMutableDictionary>?
        guard let sub = createSub(nil, channels, &resolved, 0, nil) else {
            failed = true
            return
        }
        self.channels = channels
        self.subscription = sub
    }
}
