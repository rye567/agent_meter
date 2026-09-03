import Foundation

// MARK: - GLM 编码套餐用量查询（open.bigmodel.cn）
// 接口为社区/官方插件验证的非公开 monitor 接口：
//   GET {base}/api/monitor/usage/quota/limit
//   Authorization 头直接放原始 key（无 Bearer 前缀）

enum GLMError: LocalizedError {
    case http(Int)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .http(let code):
            switch code {
            case 401: return "401 – API Key 无效或已失效"
            case 403: return "403 – 无权限（Key 可能不属于编码套餐）"
            case 429: return "429 – 请求过于频繁，稍后再试"
            default: return "HTTP \(code) – 请求失败"
            }
        case .api(let message): return message
        }
    }
}

struct GLMUsageService {
    static let defaultBaseURL = "https://open.bigmodel.cn"

    // MARK: 响应模型

    private struct QuotaResponse: Codable {
        let code: Int?
        let msg: String?
        let success: Bool?
        let data: DataPayload?
    }

    private struct DataPayload: Codable {
        let level: String?
        let limits: [LimitItem]?
    }

    private struct LimitItem: Codable {
        let type: String?
        let unit: Int?
        let number: Int?
        let percentage: Double?
        let usage: Int64?
        let remaining: Int64?
        let currentValue: Int64?
        let nextResetTime: Int64?   // epoch 毫秒
    }

    private struct BalanceResponse: Codable {
        let success: Bool?
        let data: BalanceData?
    }

    private struct BalanceData: Codable {
        let balance: Double?
        let availableBalance: Double?
    }

    // MARK: 对外接口

    static func fetchUsage(apiKey: String, includeBalance: Bool, baseURL: String? = nil) async throws -> ProviderUsage {
        let base = normalizedBase(baseURL) ?? defaultBaseURL
        let payload = try await getJSON(url: quotaURL(for: base), apiKey: apiKey, decode: QuotaResponse.self)
        guard payload.success == true || payload.code == 200 else {
            // 实测：无效 key 返回 HTTP 200 + code 1000/1001（身份验证失败），而非 401
            let keyHint = (payload.code == 1000 || payload.code == 1001) ? "（请检查 API Key）" : ""
            throw GLMError.api((payload.msg ?? "接口返回异常") + keyHint)
        }
        guard let limits = payload.data?.limits, !limits.isEmpty else {
            throw GLMError.api("未查询到配额信息（该 Key 可能没有生效中的编码套餐）")
        }

        var windows: [QuotaWindowInfo] = []
        var extras: [String] = []

        for item in limits {
            guard let type = item.type else { continue }
            let percent = min(max(item.percentage ?? 0, 0), 100)
            let resetsAt = item.nextResetTime.map { UsageFormat.date(fromEpoch: Double($0)) }

            if type == "TOKENS_LIMIT" {
                let title: String
                if item.unit == 3 && item.number == 5 {
                    title = "5 小时窗口"
                } else if item.unit == 6 {
                    title = "本周额度"
                } else if let unit = item.unit, let number = item.number {
                    title = "窗口(\(number)×\(unit))"
                } else {
                    title = "额度窗口"
                }
                let used = item.currentValue ?? item.usage
                let total: Int64? = {
                    guard let used = used, let remaining = item.remaining else { return nil }
                    return used + remaining
                }()
                windows.append(QuotaWindowInfo(
                    title: title,
                    usedPercent: percent,
                    usedTokens: used,
                    totalTokens: total,
                    resetsAt: resetsAt
                ))
            } else if type == "TIME_LIMIT" {
                extras.append("MCP 本月已用 \(Int(percent))%")
            }
        }

        guard !windows.isEmpty else {
            throw GLMError.api("未解析到 Token 额度窗口")
        }
        // "5 小时窗口"排在"本周额度"前
        windows.sort { $0.title < $1.title }

        var usage = ProviderUsage(
            displayName: AgentType.glm.displayName,
            planLevel: payload.data?.level,
            windows: windows,
            balanceText: nil,
            extraInfo: extras
        )

        if includeBalance {
            let balance = try? await fetchBalance(apiKey: apiKey, baseURL: base)
            if let balance = balance {
                usage.balanceText = String(format: "¥%.2f", balance)
            }
        }
        return usage
    }

    static func fetchBalance(apiKey: String, baseURL: String? = nil) async throws -> Double? {
        let base = normalizedBase(baseURL) ?? defaultBaseURL
        let payload = try await getJSON(url: balanceURL(for: base), apiKey: apiKey, decode: BalanceResponse.self)
        return payload.data?.balance ?? payload.data?.availableBalance
    }

    /// 设置窗口"测试连接"用
    static func testConnection(apiKey: String, baseURL: String? = nil) async -> String {
        do {
            _ = try await fetchUsage(apiKey: apiKey, includeBalance: false, baseURL: baseURL)
            return "✓ 连接成功，已获取到配额信息"
        } catch {
            if let glmError = error as? GLMError {
                return "✗ \(glmError.localizedDescription)"
            }
            return "✗ \(error.localizedDescription)"
        }
    }

    // MARK: 私有

    /// 智谱国内站与国际站（z.ai）余额接口域名不同
    private static func quotaURL(for base: String) -> URL {
        URL(string: base + "/api/monitor/usage/quota/limit")!
    }

    private static func balanceURL(for base: String) -> URL {
        if base.contains("z.ai") {
            return URL(string: "https://api.z.ai/api/biz/account/query-customer-account-report")!
        }
        return URL(string: "https://www.bigmodel.cn/api/biz/account/query-customer-account-report")!
    }

    private static func normalizedBase(_ raw: String?) -> String? {
        guard var base = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    private static func getJSON<T: Decodable>(url: URL, apiKey: String, decode: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GLMError.api("响应异常")
        }
        guard http.statusCode == 200 else {
            throw GLMError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GLMError.api("响应解析失败：\(error.localizedDescription)")
        }
    }
}
