import Foundation

// MARK: - Codex 用量
// 优先：ChatGPT 实时用量接口 wham/usage（复用 ~/.codex/auth.json 的 OAuth token，
//       URLSession 自动走系统代理 —— 与 Codex CLI 自身行为一致）
// 回退：本地解析 ~/.codex/sessions 会话文件中的 rate_limits 快照（离线可用）

struct CodexUsageService {
    static func fetchUsage() async throws -> ProviderUsage {
        do {
            return try await fetchLive()
        } catch {
            // 实时接口不可用（无 token / 401 / 网络不通）→ 本地文件兜底
            return try await fetchLocal(fallbackNote: "实时接口不可用(\(brief(error)))，来自本地会话文件")
        }
    }

    // MARK: 实时接口

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private struct LiveResponse: Decodable {
        let planType: String?
        let rateLimit: LiveRateLimit?
        let additionalRateLimits: [AdditionalLimit]?
        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
            case additionalRateLimits = "additional_rate_limits"
        }
    }

    private struct LiveRateLimit: Decodable {
        let primaryWindow: LiveWindow?
        let secondaryWindow: LiveWindow?
        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    private struct AdditionalLimit: Decodable {
        let limitName: String?
        let meteredFeature: String?
        let rateLimit: LiveRateLimit?
        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
        }
    }

    private struct LiveWindow: Decodable {
        let usedPercent: Double?
        let limitWindowSeconds: Int?
        let resetAt: Double?
        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAt = "reset_at"
        }
    }

    private static func fetchLive() async throws -> ProviderUsage {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let authURL = home.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let auth = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else {
            throw UsageError.api("未找到 Codex 登录凭据")
        }
        let accountID = tokens["account_id"] as? String

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }
        request.timeoutInterval = 12

        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UsageError.api("HTTP \(code)")
        }
        let payload = try JSONDecoder().decode(LiveResponse.self, from: body)

        var windows: [QuotaWindowInfo] = []
        // 1) 账户级窗口（每周额度，与 ChatGPT 用量页一致）
        if let top = payload.rateLimit?.primaryWindow, let percent = top.usedPercent {
            windows.append(QuotaWindowInfo(
                title: title(forSeconds: top.limitWindowSeconds, fallback: "主窗口"),
                usedPercent: clamp(percent),
                usedTokens: nil, totalTokens: nil,
                resetsAt: top.resetAt.map { UsageFormat.date(fromEpoch: $0) }
            ))
        }
        // 2) 模型级窗口（5 小时 / 每周），跳过与已有窗口同名的
        let codexEntry = payload.additionalRateLimits?.first {
            ($0.meteredFeature ?? "").contains("codex")
        } ?? payload.additionalRateLimits?.first
        if let entry = codexEntry {
            for win in [entry.rateLimit?.primaryWindow, entry.rateLimit?.secondaryWindow].compactMap({ $0 }) {
                guard let percent = win.usedPercent else { continue }
                let name = title(forSeconds: win.limitWindowSeconds, fallback: "用量窗口")
                guard !windows.contains(where: { $0.title == name }) else { continue }
                windows.append(QuotaWindowInfo(
                    title: name,
                    usedPercent: clamp(percent),
                    usedTokens: nil, totalTokens: nil,
                    resetsAt: win.resetAt.map { UsageFormat.date(fromEpoch: $0) }
                ))
            }
        }
        guard !windows.isEmpty else {
            throw UsageError.api("实时接口未返回用量窗口")
        }

        return ProviderUsage(
            displayName: AgentType.codex.displayName,
            planLevel: payload.planType,
            windows: windows,
            balanceText: nil,
            extraInfo: ["来源：ChatGPT 实时接口"]
        )
    }

    private static func title(forSeconds seconds: Int?, fallback: String) -> String {
        switch seconds {
        case 18000, 300 * 60: return "5 小时窗口"
        case 86400: return "每日窗口"
        case 604800: return "每周额度"
        default:
            guard let seconds = seconds, seconds > 0 else { return fallback }
            if seconds % 86400 == 0 { return "\(seconds / 86400) 天窗口" }
            if seconds >= 3600 { return "\(seconds / 3600) 小时窗口" }
            return "\(seconds / 60) 分钟窗口"
        }
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 100) }

    private static func brief(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.count > 40 ? String(text.prefix(40)) + "…" : text
    }

    // MARK: 本地文件兜底

    static func fetchLocal(fallbackNote: String? = nil) async throws -> ProviderUsage {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sessionsDirs = [
            home.appendingPathComponent(".codex/sessions"),
            home.appendingPathComponent(".codex/archived_sessions"),
        ]
        let files = collectRolloutFiles(in: sessionsDirs)
        guard let newest = newestFile(files) else {
            throw UsageError.notDetected("未检测到 Codex 会话记录（~/.codex/sessions）")
        }
        return try await Task.detached(priority: .utility) {
            guard let snapshot = parseRateLimits(from: newest.url) else {
                throw UsageError.api("会话文件中未找到用量快照（Codex 可能尚未运行）")
            }
            var extras: [String] = []
            if let note = fallbackNote {
                extras.append(note)
            }
            if let date = snapshot.date {
                extras.append("数据截至 \(Self.timeFormatter.string(from: date))")
            }
            return ProviderUsage(
                displayName: AgentType.codex.displayName,
                planLevel: nil,
                windows: snapshot.windows,
                balanceText: nil,
                extraInfo: extras
            )
        }.value
    }

    // MARK: 文件收集

    private struct FileCandidate {
        let url: URL
        let modified: Date
    }

    private static func collectRolloutFiles(in dirs: [URL]) -> [FileCandidate] {
        let fm = FileManager.default
        var result: [FileCandidate] = []
        for dir in dirs {
            guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { continue }
                if let modified = modificationDate(of: url) {
                    result.append(FileCandidate(url: url, modified: modified))
                }
            }
        }
        return result
    }

    private static func newestFile(_ files: [FileCandidate]) -> FileCandidate? {
        files.max { $0.modified < $1.modified }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: 解析（取文件尾部，倒序找最后一条 token_count）

    private static let tailBytes = 4 * 1024 * 1024   // 最多读 4MB 尾部

    private struct Snapshot {
        let windows: [QuotaWindowInfo]
        let date: Date?
    }

    private static func parseRateLimits(from url: URL) -> Snapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        var data: Data
        if let size = fileSize, size > tailBytes {
            _ = try? handle.seek(toOffset: UInt64(size) - UInt64(tailBytes))
            data = (try? handle.read(upToCount: tailBytes)) ?? Data()
        } else {
            data = (try? handle.readToEnd()) ?? Data()
        }
        guard !data.isEmpty else { return nil }

        // 从后往前逐行找 token_count 快照
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for rawLine in lines.reversed() {
            let lineData = Data(rawLine.utf8)
            guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { continue }
            let payload = obj["payload"] as? [String: Any]
            let eventType = (payload?["type"] as? String) ?? (obj["type"] as? String)
            guard eventType == "token_count" || obj["rate_limits"] != nil || payload?["rate_limits"] != nil else { continue }
            let rateLimits = (payload?["rate_limits"] as? [String: Any]) ?? (obj["rate_limits"] as? [String: Any])
            guard let rateLimits = rateLimits else { continue }

            var windows: [QuotaWindowInfo] = []
            if let primary = rateLimits["primary"] as? [String: Any] {
                if let w = window(from: primary, fallbackTitle: "主窗口") { windows.append(w) }
            }
            if let secondary = rateLimits["secondary"] as? [String: Any] {
                if let w = window(from: secondary, fallbackTitle: "次窗口") { windows.append(w) }
            }
            guard !windows.isEmpty else { continue }

            let snapshotDate = parseTimestamp(obj["timestamp"] as? String) ?? modificationDate(of: url)
            return Snapshot(windows: windows, date: snapshotDate)
        }
        return nil
    }

    private static func window(from dict: [String: Any], fallbackTitle: String) -> QuotaWindowInfo? {
        guard let percentAny = dict["used_percent"], let percent = doubleValue(percentAny) else { return nil }
        let minutes = (dict["window_minutes"] as? NSNumber)?.intValue
        let title = title(forSeconds: minutes.map { $0 * 60 }, fallback: fallbackTitle)
        let resetsAt = (dict["resets_at"] as? NSNumber).map { UsageFormat.date(fromEpoch: $0.doubleValue) }
        return QuotaWindowInfo(
            title: title,
            usedPercent: min(max(percent, 0), 100),
            usedTokens: nil,
            totalTokens: nil,
            resetsAt: resetsAt
        )
    }

    private static func doubleValue(_ any: Any) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func parseTimestamp(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: string) { return date }
        let iso = ISO8601DateFormatter()
        return iso.date(from: string)
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}
