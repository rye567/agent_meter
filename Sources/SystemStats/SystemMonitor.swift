import Foundation
import Combine

// MARK: - 系统监控调度器（后台串行队列采样，主线程发布）

final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot: SystemSnapshot?

    private let queue = DispatchQueue(label: "agentmeter.sysmonitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let cpuSampler = CPUSampler()
    private let diskSampler = DiskSampler()
    private let networkSampler = NetworkSampler()
    private let processSampler = ProcessSampler()
    private var history = HistoryData()

    private(set) var interval: Double = 1.5

    func start(interval: Double? = nil) {
        guard timer == nil else { return }   // 面板复用 contentViewController，避免重复启动
        if let interval = interval { self.interval = interval }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: self.interval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let snapshot = self.collect()
            DispatchQueue.main.async {
                self.snapshot = snapshot
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit {
        // 视图随开关移除时确保后台采样定时器真正停止
        timer?.cancel()
        timer = nil
    }

    private func collect() -> SystemSnapshot {
        let processes = processSampler.collect(interval: interval)
        let cpu = cpuSampler.collect()
        let memory = MemoryInfo.collect()
        let disk = diskSampler.collect(processes: processes)
        let network = networkSampler.collect()

        history.append(
            cpu: cpu.usage,
            memory: memory.totalBytes > 0
                ? Double(memory.usedBytes) / Double(memory.totalBytes) * 100 : 0,
            diskRead: disk.readBytesPerSec,
            diskWrite: disk.writeBytesPerSec,
            netUp: network.upBytesPerSec,
            netDown: network.downBytesPerSec)

        var snapshot = SystemSnapshot()
        snapshot.cpu = cpu
        snapshot.memory = memory
        snapshot.disk = disk
        snapshot.network = network
        snapshot.history = history
        return snapshot
    }
}
