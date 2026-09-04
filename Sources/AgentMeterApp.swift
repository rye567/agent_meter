import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appModel = AppModel.shared
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationService.configure()
        #if DEBUG_ICON
        for asset in ["provider_deepseek", "provider_kimi"] {
            let u1 = Bundle.main.url(forResource: asset, withExtension: "png", subdirectory: "ProviderIcons")
            let img = AppIconProvider.presetIcon(asset: asset)
            FileHandle.standardError.write("[诊断] \(asset): subdirURL=\(u1?.lastPathComponent ?? "nil") loaded=\(img != nil) size=\(img?.size.width ?? -1)\n".data(using: .utf8)!)
        }
        #endif
        setupStatusItem()
        // 首次启动（含 Spotlight/双击启动）自动弹出一次面板，避免"启动了但什么都没有"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.showPopover()
        }
    }

    /// 已运行时再次"打开"App（Spotlight 回车、双击 .app、open 命令）→ 弹出面板
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    // MARK: 状态栏图标 + 弹出面板

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        // 自定义菜单栏图标（template：单色剪影自动适配菜单栏深浅色）
        // 等比缩放到 18pt 高，宽度随原始比例自适应，避免拉伸变形
        if let url = Bundle.main.url(forResource: "menubar", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            let ratio = image.size.width / image.size.height
            image.size = NSSize(width: (18 * ratio).rounded(), height: 18)
            image.isTemplate = true
            button.image = image
            item.length = NSStatusItem.variableLength
        } else {
            let symbol = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "AgentMeter")
            symbol?.size = NSSize(width: 18, height: 18)
            button.image = symbol
        }
        button.action = #selector(togglePopover)
        button.target = self

        popover.contentViewController = NSHostingController(
            rootView: PanelView(onOpenSettings: { [weak self] in self?.openSettingsWindow() })
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
        )
        popover.contentSize = NSSize(width: 360, height: 300)
        popover.behavior = .transient
        statusItem = item
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // 每次点开面板都触发刷新（去抖合并）。
        // 不能依赖 PanelView.onAppear：NSPopover 复用 contentViewController，
        // SwiftUI 的 onAppear 只在首次显示时触发，之后点击状态栏不会再回调。
        appModel.refreshOnPanelOpen()
    }

    // MARK: 设置窗口（独立 NSWindow，避免依赖 SwiftUI 场景选择器）

    private var settingsWindow: NSWindow?

    func openSettingsWindow() {
        popover.performClose(nil)
        let window: NSWindow
        if let existing = settingsWindow {
            window = existing
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "AgentMeter 设置"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentViewController = NSHostingController(
                rootView: SettingsView()
                    .environmentObject(appModel)
                    .environmentObject(appModel.settings)
            )
            settingsWindow = window
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct AgentMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(AppModel.shared)
                .environmentObject(AppModel.shared.settings)
        }
    }
}
