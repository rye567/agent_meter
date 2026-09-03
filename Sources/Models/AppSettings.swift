import Foundation
import Combine

/// 非敏感配置（UserDefaults 持久化）；API Key 一律存钥匙串（KeychainService）
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()

    private enum Key {
        static let agents = "agents"
        static let customProviders = "customProviders"
        static let alertsEnabled = "alertsEnabled"
        static let alertThresholds = "alertThresholds"
        static let showBalance = "showBalance"
        static let refreshIntervalMinutes = "refreshIntervalMinutes"
        // 旧版键（仅迁移读取）
        static let legacyGlmEnabled = "glmEnabled"
        static let legacyCodexEnabled = "codexEnabled"
        static let legacyClaudeEnabled = "claudeEnabled"
    }

    /// 内置数据源配置（顺序即面板顺序）
    @Published var agents: [AgentConfig] = []
    /// 高级自定义余额接口（通用：endpoint + jsonPath）
    @Published var customProviders: [CustomProvider] = []
    /// GLM 是否显示账户余额
    @Published var showBalance: Bool {
        didSet { defaults.set(showBalance, forKey: Key.showBalance) }
    }
    @Published var refreshIntervalMinutes: Int {
        didSet { defaults.set(refreshIntervalMinutes, forKey: Key.refreshIntervalMinutes) }
    }
    @Published var alertsEnabled: Bool {
        didSet { defaults.set(alertsEnabled, forKey: Key.alertsEnabled) }
    }
    @Published var alertThresholds: [Int] = []

    init() {
        showBalance = defaults.object(forKey: Key.showBalance) as? Bool ?? true
        refreshIntervalMinutes = defaults.object(forKey: Key.refreshIntervalMinutes) as? Int ?? 10
        alertsEnabled = defaults.object(forKey: Key.alertsEnabled) as? Bool ?? false

        if let data = defaults.data(forKey: Key.agents),
           let list = try? JSONDecoder().decode([AgentConfig].self, from: data), list.count == AgentType.allCases.count {
            agents = list
        } else {
            agents = Self.migrateAgents(defaults: defaults)
        }

        // 自定义接口：解析并过滤掉已内置为 agent 的旧预设项
        var extras: [CustomProvider] = []
        if let data = defaults.data(forKey: Key.customProviders),
           let list = try? JSONDecoder().decode([CustomProvider].self, from: data) {
            extras = list.filter { $0.presetID == nil }
        }
        customProviders = extras

        if let data = defaults.data(forKey: Key.alertThresholds),
           let list = try? JSONDecoder().decode([Int].self, from: data), !list.isEmpty {
            alertThresholds = list
        } else {
            alertThresholds = [80]
        }

        $agents
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] list in
                if let data = try? JSONEncoder().encode(list) {
                    self?.defaults.set(data, forKey: Key.agents)
                }
            }
            .store(in: &cancellables)

        $customProviders
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] list in
                if let data = try? JSONEncoder().encode(list) {
                    self?.defaults.set(data, forKey: Key.customProviders)
                }
            }
            .store(in: &cancellables)

        $alertThresholds
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] list in
                if let data = try? JSONEncoder().encode(list.sorted()) {
                    self?.defaults.set(data, forKey: Key.alertThresholds)
                }
            }
            .store(in: &cancellables)
    }

    /// 旧版配置（三个独立开关 + 预设型自定义源）迁移为统一 agents 列表
    private static func migrateAgents(defaults: UserDefaults) -> [AgentConfig] {
        let glmOn = defaults.object(forKey: Key.legacyGlmEnabled) as? Bool ?? true
        let codexOn = defaults.object(forKey: Key.legacyCodexEnabled) as? Bool ?? true
        let claudeOn = defaults.object(forKey: Key.legacyClaudeEnabled) as? Bool ?? true

        var deepseekEnabled = false
        // 旧 customProviders 里带 presetID 的（如 DeepSeek）升级为内置 agent，钥匙串 key 一并迁移
        if let data = defaults.data(forKey: Key.customProviders),
           let list = try? JSONDecoder().decode([CustomProvider].self, from: data) {
            for extra in list {
                guard let presetID = extra.presetID, let type = AgentType(rawValue: presetID) else { continue }
                if type == .deepseek { deepseekEnabled = extra.enabled }
                let from = KeychainService.customAccount(for: extra.id)
                let to = KeychainService.agentAccount(for: type)
                if KeychainService.load(account: to) == nil,
                   let key = KeychainService.load(account: from), !key.isEmpty {
                    KeychainService.save(key, account: to)
                }
            }
        }
        // GLM key 从旧账户迁移
        if KeychainService.load(account: KeychainService.agentAccount(for: .glm)) == nil,
           let glmKey = KeychainService.load(account: KeychainService.glmKeyAccount), !glmKey.isEmpty {
            KeychainService.save(glmKey, account: KeychainService.agentAccount(for: .glm))
        }

        let list = AgentType.allCases.map { type in
            AgentConfig(
                type: type,
                enabled: type == .glm ? glmOn : type == .codex ? codexOn : type == .claude ? claudeOn : type == .deepseek ? deepseekEnabled : false,
                baseURL: nil
            )
        }
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Key.agents)
        }
        return list
    }

    func config(of type: AgentType) -> AgentConfig? {
        agents.first { $0.type == type }
    }
}
