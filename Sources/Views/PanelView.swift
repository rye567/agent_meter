import SwiftUI
import AppKit

/// 菜单栏面板（由 AppDelegate 的 NSPopover 承载）
struct PanelView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    var onOpenSettings: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // 注意：MenuBarExtra 窗口中 ScrollView 无固定高度会被压成 0，
            // 这里直接用 VStack 让内容自然撑起高度
            VStack(spacing: 10) {
                // 内置数据源（统一顺序）
                ForEach(AgentType.allCases) { type in
                    if let state = appModel.states[.agent(type)], !isDisabled(state) {
                        ProviderCardView(
                            meta: Self.meta(for: type),
                            state: state,
                            onOpenSettings: type == .glm ? { onOpenSettings?() } : nil
                        )
                    }
                }
                // 高级自定义接口
                ForEach(settings.customProviders.filter(\.enabled)) { provider in
                    if let state = appModel.states[.custom(provider.id)], !isDisabled(state) {
                        ProviderCardView(meta: Self.meta(for: provider), state: state)
                    }
                }
                if visibleCount == 0 {
                    Text("没有已启用的数据源\n在设置中开启数据源或填写 API Key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 24)
                }
            }
            .padding(12)

            Divider()

            HStack(spacing: 10) {
                Button {
                    Task { await appModel.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(appModel.isRefreshing ? 360 : 0))
                        .animation(
                            appModel.isRefreshing
                                ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                : .default,
                            value: appModel.isRefreshing
                        )
                }
                .buttonStyle(.plain)
                .disabled(appModel.isRefreshing)
                .help("立即刷新")

                if let last = appModel.lastUpdated {
                    Text("更新于 \(Self.timeFormatter.string(from: last))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    onOpenSettings?()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("设置")

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.plain)
                .help("退出 AgentMeter")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 360)
        .onAppear { appModel.refreshIfNeeded() }
    }

    private var visibleCount: Int {
        var count = 0
        for type in AgentType.allCases {
            if let state = appModel.states[.agent(type)], !isDisabled(state) { count += 1 }
        }
        for provider in settings.customProviders where provider.enabled {
            if let state = appModel.states[.custom(provider.id)], !isDisabled(state) { count += 1 }
        }
        return count
    }

    private func isDisabled(_ state: ProviderState) -> Bool {
        if case .disabled = state { return true }
        return false
    }

    // MARK: 卡片元数据

    private static func meta(for type: AgentType) -> CardMeta {
        CardMeta(
            title: type.displayName,
            nsImage: type.appBundleID.flatMap { AppIconProvider.appIcon(bundleID: $0) }
                ?? type.presetAsset.flatMap { AppIconProvider.presetIcon(asset: $0) },
            symbolName: type.symbolName,
            tint: type.tint,
            initial: String(type.displayName.prefix(1)).uppercased()
        )
    }

    private static let customTints = ["5B8DEF", "8E6FF0", "16A085", "D4875A", "C0392B", "2C7BE5"]

    private static func meta(for provider: CustomProvider) -> CardMeta {
        let tint = customTints[abs(provider.id.hashValue) % customTints.count]
        return CardMeta(
            title: provider.name,
            nsImage: nil,
            symbolName: "creditcard",
            tint: tint,
            initial: String(provider.name.prefix(1)).uppercased()
        )
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
