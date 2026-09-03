import Foundation

// MARK: - 内置数据源类型（所有 agent 一视同仁：Key + 可选 URL + 开关）

enum AgentType: String, Codable, CaseIterable, Identifiable {
    case glm
    case codex
    case claude
    case deepseek
    case moonshot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .glm: return "GLM 编码套餐"
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .deepseek: return "DeepSeek"
        case .moonshot: return "Kimi"
        }
    }

    var symbolName: String {
        switch self {
        case .glm: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .claude: return "terminal.fill"
        case .deepseek, .moonshot: return "creditcard"
        }
    }

    var tint: String {
        switch self {
        case .glm: return "3B6EF3"
        case .codex: return "10A37F"
        case .claude: return "D97757"
        case .deepseek: return "4D6BFE"
        case .moonshot: return "111111"
        }
    }

    /// 关联桌面应用（卡片显示真实 App 图标）
    var appBundleID: String? {
        switch self {
        case .glm: return "dev.zcode.app"
        case .codex: return "com.openai.codex"
        case .claude: return "com.anthropic.claudefordesktop"
        case .deepseek, .moonshot: return nil
        }
    }

    /// 打包的官方图标资源名（无对应桌面应用时使用）
    var presetAsset: String? {
        switch self {
        case .deepseek: return "provider_deepseek"
        case .moonshot: return "provider_kimi"
        default: return nil
        }
    }

    /// 是否需要 API Key（Codex 走本地 OAuth/会话，Claude 走本地扫描）
    var needsKey: Bool {
        switch self {
        case .glm, .deepseek, .moonshot: return true
        case .codex, .claude: return false
        }
    }

    var defaultBaseURL: String? {
        switch self {
        case .glm: return "https://open.bigmodel.cn"
        case .deepseek: return "https://api.deepseek.com"
        case .moonshot: return "https://api.moonshot.cn"
        case .codex, .claude: return nil
        }
    }

    /// 是否支持接口地址覆盖
    var supportsURL: Bool {
        switch self {
        case .glm, .deepseek, .moonshot: return true
        case .codex, .claude: return false
        }
    }

    var keyHint: String {
        switch self {
        case .glm: return "编码套餐 API Key（形如 id.secret）"
        case .deepseek: return "开放平台 API Key（sk-…）"
        case .moonshot: return "编码订阅 key（sk-kimi-…）或开放平台 key"
        case .codex, .claude: return ""
        }
    }
}

// MARK: - 数据源槽位

enum ProviderSlot: Hashable {
    case agent(AgentType)
    case custom(UUID)

    var keyID: String {
        switch self {
        case .agent(let type): return type.rawValue
        case .custom(let id): return id.uuidString
        }
    }
}

// MARK: - 数据源配置（持久化）

struct AgentConfig: Codable, Identifiable, Equatable {
    var type: AgentType
    var enabled: Bool
    var baseURL: String?    // 覆盖默认接口地址（如 GLM 换 api.z.ai）

    var id: String { type.rawValue }
}

// MARK: - 用量模型

struct QuotaWindowInfo: Identifiable {
    var id: String { title }
    var title: String            // "5 小时窗口" / "本周额度" / "每周窗口"
    var usedPercent: Double      // 已用百分比 0-100
    var usedTokens: Int64?       // 已用 tokens（可选，接口可能不返回）
    var totalTokens: Int64?      // 总量 tokens（可选）
    var resetsAt: Date?          // 重置时间
}

struct ProviderUsage {
    var displayName: String
    var planLevel: String?       // 套餐档位，如 "Pro"
    var windows: [QuotaWindowInfo]
    var balanceText: String?     // "¥55.19"
    var extraInfo: [String]      // 附加信息行
}

// MARK: - 数据源状态

enum ProviderState {
    case idle
    case loading
    case loaded(ProviderUsage)
    case notConfigured(String)   // 提示文案（如未填 Key）
    case notDetected(String)     // 未检测到本机数据
    case error(String)           // 请求/解析失败原因
    case disabled                // 设置中已停用，面板不展示
}

// MARK: - 错误

enum UsageError: LocalizedError {
    case notDetected(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .notDetected(let message): return message
        case .api(let message): return message
        }
    }
}

// MARK: - 工具函数

enum UsageFormat {
    /// tokens 数值格式化：1234 -> "1.2K"，1234567 -> "1.2M"
    static func tokens(_ value: Int64) -> String {
        let v = Double(value)
        if v >= 1_000_000 {
            return String(format: "%.1fM", v / 1_000_000)
        } else if v >= 1_000 {
            return String(format: "%.1fK", v / 1_000)
        }
        return "\(value)"
    }

    /// epoch 秒/毫秒自适应 -> Date
    static func date(fromEpoch value: Double) -> Date {
        let seconds = value > 1_000_000_000_000 ? value / 1000.0 : value
        return Date(timeIntervalSince1970: seconds)
    }
}
