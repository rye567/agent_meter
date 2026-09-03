import Foundation

// MARK: - Claude Code 用量：本地解析 ~/.claude/projects/**/*.jsonl
// 社区标准做法（ccusage 同源逻辑）：
//   type == "assistant" 行 -> message.usage tokens，按 message.id+requestId 去重

struct ClaudeUsageService {
    static func fetchUsage() async throws -> ProviderUsage {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // 标准目录 + 备选目录（部分安装方式使用 ~/.config/claude）
        let candidates = [
            home.appendingPathComponent(".claude/projects"),
            home.appendingPathComponent(".config/claude/projects"),
        ]
        let projectsDir = candidates.first {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
        }
        guard let projectsDir = projectsDir else {
            throw UsageError.notDetected("未检测到 Claude Code（~/.claude）")
        }
        return try await Task.detached(priority: .utility) {
            try Self.parse(projectsDir: projectsDir)
        }.value
    }

    // MARK: 解析

    private struct Aggregates {
        var today: Int64 = 0
        var week: Int64 = 0
        var fiveHours: Int64 = 0
    }

    private static func parse(projectsDir: URL) throws -> ProviderUsage {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)

        guard let enumerator = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw UsageError.api("无法读取 ~/.claude/projects")
        }

        var jsonlFiles: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            if let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               modified > cutoff {
                jsonlFiles.append(url)
            }
        }

        guard !jsonlFiles.isEmpty else {
            throw UsageError.api("近 7 天没有会话记录")
        }

        let now = Date()
        let todayStart = Calendar.current.startOfDay(for: now)
        let weekCutoff = now.addingTimeInterval(-7 * 24 * 3600)
        let fiveHourCutoff = now.addingTimeInterval(-5 * 3600)

        var aggregates = Aggregates()
        var seenKeys = Set<String>()
        var assistantEntries = 0

        for file in jsonlFiles {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(rawLine.utf8))) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let message = obj["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }

                // 去重：流式分片会重复写同一条 message
                let messageID = message["id"] as? String ?? ""
                let requestID = obj["requestId"] as? String ?? ""
                let dedupeKey = "\(messageID)|\(requestID)"
                if !messageID.isEmpty || !requestID.isEmpty {
                    if seenKeys.contains(dedupeKey) { continue }
                    seenKeys.insert(dedupeKey)
                }

                guard let timestamp = parseTimestamp(obj["timestamp"] as? String) else { continue }
                let tokens = tokenCount(usage)
                guard tokens > 0 else { continue }
                assistantEntries += 1

                if timestamp > fiveHourCutoff { aggregates.fiveHours += tokens }
                if timestamp > todayStart { aggregates.today += tokens }
                if timestamp > weekCutoff { aggregates.week += tokens }
            }
        }

        guard assistantEntries > 0 else {
            throw UsageError.api("会话文件中未解析到用量数据")
        }

        return ProviderUsage(
            displayName: AgentType.claude.displayName,
            planLevel: nil,
            windows: [],
            balanceText: nil,
            extraInfo: [
                "近 5 小时：\(UsageFormat.tokens(aggregates.fiveHours)) tokens",
                "今日：\(UsageFormat.tokens(aggregates.today)) tokens",
                "近 7 天：\(UsageFormat.tokens(aggregates.week)) tokens",
                "来源：本地会话文件（\(jsonlFiles.count) 个）",
            ]
        )
    }

    private static func tokenCount(_ usage: [String: Any]) -> Int64 {
        let fields = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
        var total: Int64 = 0
        for field in fields {
            if let n = usage[field] as? NSNumber {
                total += n.int64Value
            }
        }
        return total
    }

    private static func parseTimestamp(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: string) { return date }
        let iso = ISO8601DateFormatter()
        return iso.date(from: string)
    }
}
