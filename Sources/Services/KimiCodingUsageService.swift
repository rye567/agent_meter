import Foundation

// MARK: - Kimi For Coding 编码订阅用量
// GET {base}/v1/usages   Bearer sk-kimi-…
// 响应：usage（主窗口 limit/used/remaining/resetTime）+ limits[]（分窗口明细）

struct KimiCodingUsageService {
    static let defaultBaseURL = "https://api.kimi.com/coding"

    static func fetch(apiKey: String, baseURL: String? = nil) async throws -> ProviderUsage {
        let base = normalizedBase(baseURL) ?? defaultBaseURL
        let url = URL(string: base + "/v1/usages")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw GLMError.http(code)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GLMError.api("响应解析失败")
        }

        var windows: [QuotaWindowInfo] = []

        // 主窗口（7 天额度）
        if let usage = json["usage"] as? [String: Any],
           let window = parseWindow(usage, fallbackTitle: "7 天窗口") {
            windows.append(window)
        }
        // 分窗口明细（5 小时等）
        if let limits = json["limits"] as? [[String: Any]] {
            for item in limits {
                let windowInfo = item["window"] as? [String: Any]
                let durationMinutes = (windowInfo?["duration"] as? NSNumber)?.intValue
                guard let detail = item["detail"] as? [String: Any],
                      let window = parseWindow(detail, fallbackTitle: titleFor(minutes: durationMinutes)) else { continue }
                guard !windows.contains(where: { $0.title == window.title }) else { continue }
                windows.append(window)
            }
        }
        guard !windows.isEmpty else {
            throw GLMError.api("未解析到用量窗口")
        }
        // "5 小时窗口"排前
        windows.sort { $0.title.count < $1.title.count }

        var planLevel: String?
        if let user = json["user"] as? [String: Any],
           let membership = user["membership"] as? [String: Any],
           let level = membership["level"] as? String {
            planLevel = level
                .replacingOccurrences(of: "LEVEL_", with: "")
                . capitalizedWithLowerRest()
        }

        return ProviderUsage(
            displayName: AgentType.moonshot.displayName,
            planLevel: planLevel,
            windows: windows,
            balanceText: nil,
            extraInfo: ["来源：Kimi For Coding 编码订阅"]
        )
    }

    // MARK: 解析

    /// usage/detail 结构：limit / used / remaining（字符串数值）+ resetTime
    private static func parseWindow(_ dict: [String: Any], fallbackTitle: String) -> QuotaWindowInfo? {
        guard let limit = double(dict["limit"]), limit > 0 else { return nil }
        let used = double(dict["used"]) ?? (limit - (double(dict["remaining"]) ?? 0))
        let percent = min(max(used / limit * 100, 0), 100)
        let resetsAt = (dict["resetTime"] as? String).flatMap(parseISO)
        return QuotaWindowInfo(
            title: fallbackTitle,
            usedPercent: percent,
            usedTokens: nil,
            totalTokens: nil,
            resetsAt: resetsAt
        )
    }

    private static func titleFor(minutes: Int?) -> String {
        switch minutes {
        case 300: return "5 小时窗口"
        case 1440: return "每日窗口"
        case 10080: return "7 天窗口"
        default:
            guard let minutes = minutes, minutes > 0 else { return "用量窗口" }
            if minutes % 1440 == 0 { return "\(minutes / 1440) 天窗口" }
            if minutes >= 60 { return "\(minutes / 60) 小时窗口" }
            return "\(minutes) 分钟窗口"
        }
    }

    private static func double(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func parseISO(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func normalizedBase(_ raw: String?) -> String? {
        guard var base = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { base.removeLast(3) }
        // 误填了开放平台地址时回退默认编码地址
        if base.contains("moonshot.cn") { return nil }
        return base
    }
}

private extension String {
    /// "INTERMEDIATE" -> "Intermediate"
    func capitalizedWithLowerRest() -> String {
        guard let first = first else { return self }
        return String(first) + dropFirst().lowercased()
    }
}
