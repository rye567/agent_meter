import SwiftUI
import AppKit

// MARK: - 已安装应用图标获取

enum AppIconProvider {
    /// 优先读应用内 icns（多分辨率高清），失败退回 NSWorkspace 图标；未安装返回 nil
    static func appIcon(bundleID: String) -> NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        if let bundle = Bundle(url: appURL),
           let icns = bundle.urls(forResourcesWithExtension: "icns", subdirectory: nil)?.first,
           let image = NSImage(contentsOf: icns) {
            return image
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    private static let presetIconAssets = [
        "deepseek": "provider_deepseek",
        "moonshot": "provider_kimi",
    ]

    /// 内置预设的官方图标（打包在 ProviderIcons 资源里；注意子目录查找）
    static func presetIcon(asset: String) -> NSImage? {
        let name = presetIconAssets[asset] ?? asset
        #if DEBUG_ICON
        let u1 = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "ProviderIcons")
        let u2 = Bundle.main.url(forResource: name, withExtension: "png")
        FileHandle.standardError.write("[诊断] presetIcon(\(asset)) subdir=\(u1?.path ?? "nil") flat=\(u2?.path ?? "nil")\n".data(using: .utf8)!)
        #endif
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "ProviderIcons"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return Bundle.main.image(forResource: name)
    }
}

// MARK: - 卡片展示元数据

struct CardMeta {
    var title: String
    var nsImage: NSImage?    // 真实应用图标（内置源动态取）
    var symbolName: String   // SF Symbol 兜底
    var tint: String
    var initial: String?     // 字母头像（自定义源）
}

/// 单个数据源卡片
struct ProviderCardView: View {
    let meta: CardMeta
    let state: ProviderState
    var onOpenSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: 头部

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            appIconView
                .frame(width: 24, height: 24)
            Text(meta.title)
                .font(.system(size: 13, weight: .semibold))
            if case .loaded(let usage) = state, let level = usage.planLevel, !level.isEmpty {
                StatusBadge(text: level, color: .blue)
            }
            Spacer()
            stateBadge
        }
    }

    /// 图标优先级：真实应用图标 > 字母头像 > SF Symbol 色块
    @ViewBuilder
    private var appIconView: some View {
        if let nsImage = meta.nsImage {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
        } else if let initial = meta.initial {
            Text(initial)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color(hex: meta.tint), in: RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: meta.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: meta.tint))
                .frame(width: 24, height: 24)
                .background(Color(hex: meta.tint).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch state {
        case .idle, .loading:
            StatusBadge(text: "加载中", color: .secondary)
        case .loaded:
            StatusBadge(text: "正常", color: .green)
        case .notConfigured, .notDetected:
            StatusBadge(text: "未就绪", color: .orange)
        case .error:
            StatusBadge(text: "异常", color: .red)
        case .disabled:
            EmptyView()
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .frame(height: 30)

        case .loaded(let usage):
            ForEach(usage.windows) { window in
                windowRow(window)
            }
            if let balance = usage.balanceText {
                InfoRow(icon: "creditcard", text: "账户余额：\(balance)")
            }
            ForEach(usage.extraInfo, id: \.self) { info in
                InfoRow(icon: "info.circle", text: info)
            }

        case .notConfigured(let message), .notDetected(let message), .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .notConfigured = state, let onOpenSettings = onOpenSettings {
                    Button(action: onOpenSettings) {
                        Label("去设置", systemImage: "gearshape")
                            .font(.caption)
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .disabled:
            EmptyView()
        }
    }

    private func windowRow(_ window: QuotaWindowInfo) -> some View {
        let used = min(max(window.usedPercent, 0), 100)
        return VStack(spacing: 4) {
            HStack {
                Text(window.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                if let used = window.usedTokens, let total = window.totalTokens, total > 0 {
                    Text("\(UsageFormat.tokens(used)) / \(UsageFormat.tokens(total))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(used))%")
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(used >= 80 ? .red : (used >= 60 ? .orange : .primary))
            }
            UsageProgressBar(percent: window.usedPercent)
            if let resetsAt = window.resetsAt {
                HStack {
                    CountdownText(resetsAt: resetsAt)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Color(hex:)

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
