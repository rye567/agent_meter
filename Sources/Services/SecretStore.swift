import Foundation
import Security

/// API Key 本地存储：~/Library/Application Support/AgentMeter/keys.json（文件 0600 / 目录 0700）。
/// 刻意不使用登录钥匙串：钥匙串 ACL 与代码签名绑定，跨版本/跨机器更新会触发
/// 「想要访问钥匙串」系统密码弹窗，对分发场景不可接受。0600 文件仅当前用户可读，
/// 与 gh / aws 等主流 CLI 的凭据存储方式一致。
///
/// 旧版钥匙串迁移：`migrateLegacyIfNeeded` 只在升级后首次启动执行一次
/// （UserDefaults 标记），无论成功、条目不存在还是用户点了「拒绝」，此后
/// 进程与后续版本都永不触碰钥匙串。被拒绝的账户由用户在设置中重新填写。
enum SecretStore {
    static let glmKeyAccount = "glm_api_key"               // 旧账户名，仅迁移用

    private static let migrationFlagKey = "legacyKeychainMigrated"

    static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentMeter", isDirectory: true)
            .appendingPathComponent("keys.json")
    }

    private static func loadStore() -> [String: String] {
        guard let data = try? Data(contentsOf: storeURL),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return [:] }
        return dict
    }

    private static func writeStore(_ dict: [String: String]) {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: dict).write(to: storeURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }

    /// 内置数据源的存储账户名
    static func agentAccount(for type: AgentType) -> String {
        "agent.\(type.rawValue)"
    }

    /// 自定义数据源的存储账户名
    static func customAccount(for id: UUID) -> String {
        "custom.\(id.uuidString)"
    }

    static func load(account: String) -> String? {
        let value = loadStore()[account] ?? ""
        return value.isEmpty ? nil : value
    }

    static func save(_ value: String, account: String) {
        var store = loadStore()
        if value.isEmpty {
            store.removeValue(forKey: account)
        } else {
            store[account] = value
        }
        writeStore(store)
    }

    static func delete(account: String) {
        var store = loadStore()
        store.removeValue(forKey: account)
        writeStore(store)
    }

    /// 升级后一次性迁移：把旧钥匙串条目搬入文件并删除原条目。
    /// 由应用启动时调用一次；成败与否都写标记，保证此后永不读钥匙串。
    static func migrateLegacyIfNeeded(accounts: [String]) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: migrationFlagKey) == false else { return }
        defaults.set(true, forKey: migrationFlagKey)

        var store = loadStore()
        var migrated = 0
        for account in accounts {
            guard store[account] == nil || store[account]!.isEmpty else { continue }
            if let value = KeychainLegacy.load(account: account), !value.isEmpty {
                store[account] = value
                KeychainLegacy.delete(account: account)
                migrated += 1
            } else {
                KeychainLegacy.delete(account: account)   // 不存在或被拒绝：清掉残留元数据
            }
        }
        if migrated > 0 || !accounts.isEmpty {
            writeStore(store)
        }
        if migrated > 0 {
            FileHandle.standardError.write("[AgentMeter] 已从钥匙串迁移 \(migrated) 个凭据\n".data(using: .utf8)!)
        }
    }
}

/// 旧版钥匙串存储（仅由 SecretStore 的迁移路径调用）
private enum KeychainLegacy {
    static let legacyServiceName = "agent_meter"

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyServiceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyServiceName,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
