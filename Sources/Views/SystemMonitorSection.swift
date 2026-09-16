import SwiftUI
import Charts

// MARK: - 系统监控内部面板（四宫格：CPU / 内存 / 磁盘 / 网络波浪图）

struct SystemMonitorSection: View {
    @StateObject private var monitor = SystemMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "gauge")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("系统监控")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                if monitor.snapshot == nil {
                    Text("正在采集…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let snap = monitor.snapshot {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 8
                ) {
                    SystemCell(
                        title: "CPU", icon: "cpu", tint: .blue,
                        value: SysFormat.percent(snap.cpu.usage),
                        badge: snap.cpu.temperatureC.map { SysFormat.temperature($0) },
                        subline: cpuSubline(snap.cpu),
                        chart: WaveChart(
                            series: [.init(name: "CPU", values: snap.history.cpu, color: .blue)],
                            yMax: 100)
                    )
                    SystemCell(
                        title: "内存", icon: "memorychip", tint: .teal,
                        value: snap.memory.totalBytes > 0
                            ? SysFormat.bytes(snap.memory.usedBytes, decimals: 0)
                            : "—",
                        badge: nil,
                        subline: memorySubline(snap.memory),
                        chart: WaveChart(
                            series: [.init(name: "内存", values: snap.history.memory, color: .teal)],
                            yMax: 100)
                    )
                    SystemCell(
                        title: "磁盘", icon: "internaldrive", tint: .orange,
                        value: diskValue(snap.disk),
                        badge: nil,
                        subline: "R \(SysFormat.speed(snap.disk.readBytesPerSec)) · W \(SysFormat.speed(snap.disk.writeBytesPerSec))",
                        chart: WaveChart(series: [
                            .init(name: "读", values: snap.history.diskRead, color: .orange),
                            .init(name: "写", values: snap.history.diskWrite, color: .pink),
                        ])
                    )
                    SystemCell(
                        title: "网络", icon: "wifi", tint: .green,
                        value: "↓ \(SysFormat.speed(snap.network.downBytesPerSec))",
                        badge: nil,
                        subline: "↑ \(SysFormat.speed(snap.network.upBytesPerSec))",
                        chart: WaveChart(series: [
                            .init(name: "↑", values: snap.history.netUp, color: .green),
                            .init(name: "↓", values: snap.history.netDown, color: .blue),
                        ])
                    )
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small).padding(.vertical, 18)
                    Spacer()
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .onAppear { monitor.start() }
    }

    private func cpuSubline(_ cpu: CPUSnapshot) -> String {
        var parts: [String] = []
        if let f = cpu.frequencyMHz { parts.append("P≈" + SysFormat.frequency(f)) }
        if let f = cpu.eFrequencyMHz { parts.append("E≈" + SysFormat.frequency(f)) }
        return parts.isEmpty ? cpu.chipName : parts.joined(separator: " ")
    }

    private func memorySubline(_ memory: MemorySnapshot) -> String {
        var parts: [String] = ["已用 \(SysFormat.bytes(memory.usedBytes, decimals: 0))"]
        if memory.swapUsedBytes > 0 { parts.append("Swap \(SysFormat.bytes(memory.swapUsedBytes, decimals: 0))") }
        return parts.joined(separator: " · ")
    }

    private func diskValue(_ disk: DiskSnapshot) -> String {
        disk.writeBytesPerSec > 1 || disk.readBytesPerSec > 1
            ? SysFormat.speed(disk.writeBytesPerSec)
            : "空闲"
    }
}

// MARK: - 单个监控格子

struct SystemCell: View {
    let title: String
    let icon: String
    let tint: Color
    let value: String
    let badge: String?
    let subline: String
    let chart: WaveChart

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(tint.opacity(0.14), in: Capsule())
                        .foregroundStyle(tint)
                }
                Text(value)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            chart
                .frame(height: 34)
                .frame(maxWidth: .infinity)
            Text(subline)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - 波浪图（滚动历史曲线：面积渐变 + 平滑线条）

struct WaveChart: View {
    struct Series {
        let name: String
        let values: [Double]
        let color: Color
    }

    let series: [Series]
    var yMax: Double? = nil   // nil = 按峰值自动缩放

    var body: some View {
        Chart {
            ForEach(series, id: \.name) { s in
                ForEach(Array(s.values.enumerated()), id: \.offset) { index, value in
                    AreaMark(
                        x: .value("i", index),
                        y: .value("v", value),
                        series: .value("s", s.name)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [s.color.opacity(0.38), s.color.opacity(0.04)],
                            startPoint: .top, endPoint: .bottom))
                    LineMark(
                        x: .value("i", index),
                        y: .value("v", value),
                        series: .value("s", s.name)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(s.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            }
        }
        .chartXScale(domain: 0...Double(max(HistoryData.capacity - 1, 1)))
        .chartYScale(domain: 0...(yMax ?? autoMax()))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot.background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private func autoMax() -> Double {
        let peak = series.flatMap(\.values).max() ?? 0
        return max(peak * 1.2, 1024)
    }
}
