import Foundation
import Combine

extension Notification.Name {
    /// API Key 变更后触发立即刷新
    static let agentKeyChanged = Notification.Name("agentMeter.keyChanged")
}

/// 全局状态中枢：定时刷新 + 各数据源状态 + 阈值提醒
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings = SettingsStore()

    @Published var states: [ProviderSlot: ProviderState] = [:]
    @Published var lastUpdated: Date?
    @Published var isRefreshing = false

    private var autoTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// 各窗口已提醒的最高阈值（key = slot|窗口名），回落到最低阈值以下时重置
    private var alertedLevels: [String: Int] = [:]

    init() {
        settings.objectWillChange
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.startAutoRefresh() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: Notification.Name.agentKeyChanged)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.startAutoRefresh() }
            .store(in: &cancellables)

        startAutoRefresh()
    }

    // MARK: 刷新调度

    func startAutoRefresh() {
        autoTask?.cancel()
        let intervalSeconds = max(60, settings.refreshIntervalMinutes * 60)
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds) * 1_000_000_000)
            }
        }
    }

    /// 面板打开时调用：数据过期（>1 分钟）才刷新
    func refreshIfNeeded() {
        guard let last = lastUpdated else {
            Task { await refreshAll() }
            return
        }
        if Date().timeIntervalSince(last) > 60 {
            Task { await refreshAll() }
        }
    }

    func refreshAll() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let s = settings

        // 内置数据源（并发）
        let agentResults = await withTaskGroup(of: (AgentType, ProviderState).self) { group in
            for agent in s.agents {
                let key = agent.type.needsKey
                    ? KeychainService.load(account: KeychainService.agentAccount(for: agent.type))
                    : nil
                group.addTask {
                    (agent.type, await Self.fetchAgent(agent, key: key, showBalance: s.showBalance))
                }
            }
            var out: [(AgentType, ProviderState)] = []
            for await item in group { out.append(item) }
            return out
        }

        // 高级自定义接口（并发）
        let enabledCustoms = s.customProviders.filter(\.enabled)
        let customResults = await withTaskGroup(of: (UUID, ProviderState).self) { group in
            for provider in enabledCustoms {
                let key = KeychainService.load(account: KeychainService.customAccount(for: provider.id))
                group.addTask {
                    (provider.id, await Self.fetchCustom(provider, key: key))
                }
            }
            var out: [(UUID, ProviderState)] = []
            for await item in group { out.append(item) }
            return out
        }

        var results: [ProviderSlot: ProviderState] = [:]
        for (type, state) in agentResults { results[.agent(type)] = state }
        for (id, state) in customResults { results[.custom(id)] = state }

        states = results
        lastUpdated = Date()
        checkAlerts()
    }

    // MARK: 单源拉取（互不影响）

    private static func fetchAgent(_ agent: AgentConfig, key: String?, showBalance: Bool) async -> ProviderState {
        let type = agent.type
        guard agent.enabled else { return .disabled }
        if type.needsKey, key == nil || key!.isEmpty {
            return .notConfigured("未配置 API Key，点击设置添加")
        }
        do {
            switch type {
            case .glm:
                return .loaded(try await GLMUsageService.fetchUsage(
                    apiKey: key!, includeBalance: showBalance, baseURL: agent.baseURL
                ))
            case .codex:
                return .loaded(try await CodexUsageService.fetchUsage())
            case .claude:
                return .loaded(try await ClaudeUsageService.fetchUsage())
            case .deepseek, .moonshot:
                let base = normalized(agent.baseURL) ?? type.defaultBaseURL!
                // Kimi 编码订阅 key（sk-kimi-…）走编码用量接口；开放平台 key 走余额接口
                if type == .moonshot, key!.hasPrefix("sk-kimi") {
                    do {
                        return .loaded(try await KimiCodingUsageService.fetch(apiKey: key!, baseURL: agent.baseURL))
                    } catch {
                        return .error(describe(error))
                    }
                }
                let provider = CustomProvider(
                    name: type.displayName,
                    endpoint: type == .deepseek ? base + "/user/balance" : base + "/v1/users/me/balance",
                    jsonPath: type == .deepseek ? "balance_infos.0.total_balance" : "data.balance",
                    currency: type == .deepseek ? "¥" : "$",
                    presetID: type.rawValue
                )
                do {
                    return .loaded(try await CustomUsageService.fetch(provider: provider, apiKey: key!))
                } catch {
                    return .error(CustomUsageService.friendlyError(error, type: type))
                }
            }
        } catch {
            return errorState(error)
        }
    }

    private static func fetchCustom(_ provider: CustomProvider, key: String?) async -> ProviderState {
        guard let key = key, !key.isEmpty else { return .notConfigured("未配置 API Key，点击设置添加") }
        do {
            return .loaded(try await CustomUsageService.fetch(provider: provider, apiKey: key))
        } catch {
            return errorState(error)
        }
    }

    private static func normalized(_ raw: String?) -> String? {
        guard var base = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    private static func errorState(_ error: Error) -> ProviderState {
        if let usageError = error as? UsageError, case .notDetected = usageError {
            return .notDetected(usageError.localizedDescription)
        }
        return .error(describe(error))
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return error.localizedDescription
    }

    // MARK: 阈值提醒

    private func checkAlerts() {
        guard settings.alertsEnabled else { return }
        let thresholds = settings.alertThresholds.sorted()
        guard let lowest = thresholds.first else { return }

        struct Crossing {
            let agent: String
            let window: String
            let usedPercent: Double
            let threshold: Int
            let resetsAt: Date?
            let tokensText: String?
        }
        var crossed: [Crossing] = []

        for (slot, state) in states {
            guard case .loaded(let usage) = state else { continue }
            for window in usage.windows {
                let key = "\(slot.keyID)|\(window.title)"
                let hit = thresholds.filter { window.usedPercent >= Double($0) }.max()
                if let hit = hit {
                    if hit > (alertedLevels[key] ?? 0) {
                        alertedLevels[key] = hit
                        var tokensText: String?
                        if let used = window.usedTokens, let total = window.totalTokens, total > 0 {
                            tokensText = "已用 \(UsageFormat.tokens(used)) / \(UsageFormat.tokens(total)) tokens"
                        }
                        crossed.append(Crossing(
                            agent: usage.displayName,
                            window: window.title,
                            usedPercent: window.usedPercent,
                            threshold: hit,
                            resetsAt: window.resetsAt,
                            tokensText: tokensText
                        ))
                    }
                } else if window.usedPercent < Double(lowest), alertedLevels[key] != nil {
                    // 已回落（窗口重置/用量清零），允许下次再触发
                    alertedLevels[key] = nil
                }
            }
        }

        guard !crossed.isEmpty else { return }

        if crossed.count == 1 {
            let c = crossed[0]
            var body = "剩余 \(100 - Int(c.usedPercent))%，已达提醒阈值 \(c.threshold)%"
            if let tokensText = c.tokensText { body += "（\(tokensText)）" }
            if let resetsAt = c.resetsAt {
                body += " · " + CountdownText.string(until: resetsAt)
            }
            NotificationService.post(
                title: "\(c.agent) · \(c.window) 已用 \(Int(c.usedPercent))%",
                body: body
            )
        } else {
            // 多窗口同时越线：合并为一条汇总通知
            let lines = crossed.map { c -> String in
                var line = "• \(c.agent) \(c.window)：已用 \(Int(c.usedPercent))%（剩余 \(100 - Int(c.usedPercent))%）"
                if let tokensText = c.tokensText { line += "，\(tokensText)" }
                return line
            }
            NotificationService.post(
                title: "用量提醒：\(crossed.count) 个窗口达到阈值",
                body: lines.joined(separator: "\n")
            )
        }
    }
}
