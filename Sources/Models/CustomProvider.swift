import Foundation

// MARK: - 通用自定义余额类数据源
// 适用：任何「GET + Bearer 认证 + 响应 JSON 中含余额数值」的接口。
// 通过 endpoint + jsonPath（点路径，如 balance_infos.0.total_balance）描述取数字段。

struct CustomProvider: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var endpoint: String        // 完整接口地址
    var jsonPath: String        // 余额字段点路径，"0" 表示数组下标
    var currency: String        // 货币符号，如 ¥ / $
    var presetID: String?       // 命中内置预设时使用其官方图标
    var enabled: Bool

    init(id: UUID = UUID(), name: String, endpoint: String, jsonPath: String,
         currency: String, presetID: String? = nil, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.jsonPath = jsonPath
        self.currency = currency
        self.presetID = presetID
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, endpoint, jsonPath, currency, presetID, enabled
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case style, baseURL, enabled, presetID, currency, id, name
    }

    /// 解码，并兼容旧版 style+baseURL 结构
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID)
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? ""
        if let endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint),
           let jsonPath = try c.decodeIfPresent(String.self, forKey: .jsonPath) {
            self.endpoint = endpoint
            self.jsonPath = jsonPath
        } else {
            // 旧 schema 迁移
            let l = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let styleRaw = try l.decodeIfPresent(String.self, forKey: .style) ?? "deepseek"
            var base = try l.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
            while base.hasSuffix("/") { base.removeLast() }
            if styleRaw == "moonshot" {
                endpoint = base + "/v1/users/me/balance"
                jsonPath = "data.balance"
                currency = "$"
                presetID = "moonshot"
            } else {
                endpoint = base + "/user/balance"
                jsonPath = "balance_infos.0.total_balance"
                currency = "¥"
                presetID = "deepseek"
            }
        }
    }
}
