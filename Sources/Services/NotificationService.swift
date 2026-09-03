import Foundation
import UserNotifications

/// 系统通知（用量阈值提醒）
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// 应用处于前台时也显示横幅（默认行为是静默进通知中心）
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

enum NotificationService {
    private static let delegate = NotificationDelegate()

    /// 尽早调用：注册前台展示 delegate
    static func configure() {
        UNUserNotificationCenter.current().delegate = delegate
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// 设置面板的测试按钮：确保权限并发送，把结果回传给界面
    static func postTest(done: @escaping (String) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                if let error = error {
                    done("✗ 请求通知权限失败：\(error.localizedDescription)")
                    return
                }
                if !granted {
                    done("✗ 通知权限被拒绝：请到 系统设置 → 通知 → AgentMeter 打开「允许通知」后重试")
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = "AgentMeter 测试提醒"
                content.body = "通知权限正常 ✓ 用量达到阈值时会在这里提醒你"
                content.sound = .default
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { addError in
                    DispatchQueue.main.async {
                        if let addError = addError {
                            done("✗ 发送失败：\(addError.localizedDescription)")
                        } else {
                            done("✓ 测试通知已发送")
                        }
                    }
                }
            }
        }
    }
}
