import SwiftUI
import ServiceManagement

/// 设置窗口
struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore

    @State private var notifResult: String?
    @State private var loginItemOn = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                ForEach($settings.agents) { $agent in
                    AgentConfigRow(config: $agent)
                }
            } header: {
                Text("数据源")
            }

            Section {
                Toggle("达到阈值时发送系统通知", isOn: $settings.alertsEnabled)
                    .onChange(of: settings.alertsEnabled) { _, enabled in
                        if enabled { NotificationService.requestAuthorization() }
                    }
                HStack {
                    Button("发送测试通知") {
                        NotificationService.postTest { result in
                            notifResult = result
                        }
                    }
                    if settings.alertsEnabled {
                        ThresholdEditor(thresholds: $settings.alertThresholds)
                    }
                }
                if let notifResult = notifResult {
                    Text(notifResult)
                        .font(.caption)
                        .foregroundStyle(notifResult.hasPrefix("✓") ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if settings.alertsEnabled {
                    Text("每个用量窗口在每个阈值只提醒一次，窗口重置后重新计算。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("用量提醒")
            }

            Section {
                Picker("自动刷新间隔", selection: $settings.refreshIntervalMinutes) {
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                    Text("30 分钟").tag(30)
                    Text("60 分钟").tag(60)
                }
                .pickerStyle(.radioGroup)
                Toggle("登录时自动启动", isOn: $loginItemOn)
                    .onChange(of: loginItemOn) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginItemError = nil
                        } catch {
                            loginItemError = "设置失败：\(error.localizedDescription)"
                        }
                    }
                if let loginItemError = loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("开启登录启动前，建议先把 App 移到「应用程序」文件夹。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("刷新与启动")
            }

            Section {
                LabeledContent("版本") { Text("0.1.0") }
                LabeledContent("应用") { Text("AgentMeter") }
            } header: {
                Text("关于")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 680)
    }
}

// MARK: - 单个内置数据源配置行（Key + 可选 URL + 开关，一视同仁）

struct AgentConfigRow: View {
    @Binding var config: AgentConfig
    @EnvironmentObject private var settings: SettingsStore

    @State private var keyDraft = ""
    @State private var urlDraft = ""
    @State private var showKey = false
    @State private var showURL = false
    @State private var testResult: String?
    @State private var isTesting = false

    private var type: AgentType { config.type }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                iconView
                    .frame(width: 22, height: 22)
                Text(type.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("", isOn: $config.enabled)
                    .labelsHidden()
                    .controlSize(.small)
            }

            if type.needsKey {
                HStack(spacing: 6) {
                    Group {
                        if showKey {
                            TextField("API Key", text: $keyDraft)
                        } else {
                            SecureField("API Key", text: $keyDraft)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .layoutPriority(1)

                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help(showKey ? "隐藏" : "显示")

                    Button("测试") {
                        runTest()
                    }
                    .font(.caption)
                    .fixedSize()
                    .disabled(keyDraft.isEmpty || isTesting)
                    if isTesting {
                        ProgressView().controlSize(.small).fixedSize()
                    }
                }

                if type.supportsURL {
                    DisclosureGroup(isExpanded: $showURL) {
                        TextField("接口地址（默认 \(type.defaultBaseURL ?? "")）", text: $urlDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .onChange(of: urlDraft) { _, newValue in
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                config.baseURL = trimmed.isEmpty ? nil : trimmed
                            }
                        if type == .glm {
                            Toggle("显示账户余额", isOn: $settings.showBalance)
                                .font(.caption)
                        }
                    } label: {
                        Text("接口地址")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let testResult = testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(testResult.hasPrefix("✓") ? .green : .red)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(type == .codex ? "本机自动：本地会话 + ChatGPT 实时接口，无需配置" : "本机自动：扫描本地会话文件，无需配置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            keyDraft = KeychainService.load(account: KeychainService.agentAccount(for: type)) ?? ""
            urlDraft = config.baseURL ?? ""
            showURL = !(urlDraft.isEmpty)
        }
        // Key 自动保存（0.4s 防抖）
        .task(id: keyDraft) {
            guard type.needsKey else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            KeychainService.save(keyDraft, account: KeychainService.agentAccount(for: type))
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let bundleID = type.appBundleID, let nsImage = AppIconProvider.appIcon(bundleID: bundleID) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else if let asset = type.presetAsset, let nsImage = AppIconProvider.presetIcon(asset: asset) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            Image(systemName: type.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(hex: type.tint))
                .frame(width: 22, height: 22)
                .background(Color(hex: type.tint).opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        let key = keyDraft
        let url = urlDraft.isEmpty ? nil : urlDraft
        Task {
            let result: String
            switch type {
            case .glm:
                result = await GLMUsageService.testConnection(apiKey: key, baseURL: url)
            case .deepseek, .moonshot:
                // Kimi 编码订阅 key（sk-kimi-…）走编码用量接口
                if type == .moonshot, key.hasPrefix("sk-kimi") {
                    do {
                        let usage = try await KimiCodingUsageService.fetch(apiKey: key, baseURL: url)
                        result = "✓ 连接成功，已获取到 \(usage.windows.count) 个用量窗口"
                    } catch {
                        result = "✗ " + ((error as? GLMError)?.errorDescription ?? error.localizedDescription)
                    }
                } else {
                    let base = url ?? type.defaultBaseURL ?? ""
                    let provider = CustomProvider(
                        name: type.displayName,
                        endpoint: type == .deepseek ? base + "/user/balance" : base + "/v1/users/me/balance",
                        jsonPath: type == .deepseek ? "balance_infos.0.total_balance" : "data.balance",
                        currency: type == .deepseek ? "¥" : "$",
                        presetID: type.rawValue
                    )
                    do {
                        let usage = try await CustomUsageService.fetch(provider: provider, apiKey: key)
                        result = "✓ 连接成功：余额 \(usage.balanceText ?? "-")"
                    } catch {
                        result = "✗ " + CustomUsageService.friendlyError(error, type: type)
                    }
                }
            case .codex, .claude:
                result = ""
            }
            await MainActor.run {
                testResult = result
                isTesting = false
            }
        }
    }
}
