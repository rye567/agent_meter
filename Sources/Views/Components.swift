import SwiftUI

// MARK: - 用量进度条

struct UsageProgressBar: View {
    let percent: Double   // 已用百分比 0-100

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                // 绿色代表剩余量：用量越大绿条越短
                Capsule()
                    .fill(barColor)
                    .frame(width: max(3, geo.size.width * remaining / 100))
            }
        }
        .frame(height: 6)
    }

    private var remaining: Double {
        100 - min(max(percent, 0), 100)
    }

    /// 颜色跟随剩余量：剩余 ≤20% 红色告急，≤40% 橙色预警
    private var barColor: Color {
        if remaining <= 20 { return .red }
        if remaining <= 40 { return .orange }
        return .green
    }
}

// MARK: - 重置倒计时（自动刷新）

struct CountdownText: View {
    let resetsAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            Text(Self.string(until: resetsAt))
        }
    }

    static func string(until date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 { return "已重置" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 24 {
            return "\(h / 24) 天 \(h % 24) 小时后重置"
        }
        return h > 0 ? "\(h) 小时 \(m) 分后重置" : "\(m) 分后重置"
    }
}

// MARK: - 状态徽章

struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - 附加信息行

struct InfoRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - 用量提醒阈值选择（预设多选）

struct ThresholdEditor: View {
    @Binding var thresholds: [Int]

    private let presets = [50, 60, 70, 80, 90]

    var body: some View {
        HStack(spacing: 8) {
            Text("提醒阈值")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(presets, id: \.self) { t in
                chip(t)
            }
        }
    }

    private func chip(_ value: Int) -> some View {
        let active = thresholds.contains(value)
        return Button {
            if active {
                thresholds.removeAll { $0 == value }
            } else {
                thresholds.append(value)
            }
        } label: {
            Text("\(value)%")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(active ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                )
                .foregroundStyle(active ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
    }
}
