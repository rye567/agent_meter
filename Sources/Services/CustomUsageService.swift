import Foundation

// MARK: - 通用自定义数据源用量查询
// 任意「GET + Bearer + JSON 点路径取值」的余额接口

enum CustomUsageService {
    static func fetch(provider: CustomProvider, apiKey: String) async throws -> ProviderUsage {
        guard let url = URL(string: provider.endpoint) else {
            throw GLMError.api("接口地址无效：\(provider.endpoint)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GLMError.api("响应异常")
        }
        guard http.statusCode == 200 else {
            throw GLMError.http(http.statusCode)
        }

        let json = try? JSONSerialization.jsonObject(with: data)
        guard let amount = resolve(path: provider.jsonPath, in: json) else {
            throw GLMError.api("未在响应中找到字段 \"\(provider.jsonPath)\"，请检查字段路径")
        }
        return ProviderUsage(
            displayName: provider.name,
            planLevel: nil,
            windows: [],
            balanceText: provider.currency + amount,
            extraInfo: []
        )
    }

    /// 设置窗口"测试连接"
    static func test(provider: CustomProvider, apiKey: String) async -> String {
        do {
            let usage = try await fetch(provider: provider, apiKey: apiKey)
            return "✓ 连接成功：余额 \(usage.balanceText ?? "-")"
        } catch {
            if let glmError = error as? GLMError {
                return "✗ \(glmError.localizedDescription)"
            }
            return "✗ \(error.localizedDescription)"
        }
    }

    /// 面向用户的错误文案（特殊化 Kimi 编码订阅 key 的余额 404/401）
    static func friendlyError(_ error: Error, type: AgentType) -> String {
        if type == .moonshot,
           let glmError = error as? GLMError,
           case .http(let code) = glmError,
           code == 401 || code == 404 {
            return "当前 Key 无法查询余额：Kimi 编码订阅 key 不支持，需要 Moonshot 开放平台 Key（platform.moonshot.cn）"
        }
        if let glmError = error as? GLMError, let message = glmError.errorDescription {
            return message
        }
        return error.localizedDescription
    }

    // MARK: JSON 点路径解析（"a.b.0.c"，数字段为数组下标）

    private static func resolve(path: String, in json: Any?) -> String? {
        var current = json
        for component in path.split(separator: ".").map(String.init) {
            if let dict = current as? [String: Any] {
                current = dict[component]
            } else if let array = current as? [Any], let index = Int(component), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        switch current {
        case let number as NSNumber:
            return number.stringValue
        case let string as String:
            return string
        default:
            return nil
        }
    }
}
