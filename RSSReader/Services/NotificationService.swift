import Foundation
import UserNotifications
import UIKit
import SwiftData

/// 새 글 로컬 알림. 유료 계정이 없어 원격 푸시는 쓰지 않고,
/// 앱을 열 때와 백그라운드 갱신이 돌 때 발견한 새 글만 알린다.
enum NotificationService {
    /// 기기별 마스터 스위치 (동기화하지 않음: 권한이 기기마다 다르다)
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppSettingsKeys.notificationsEnabled)
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 권한을 요청하고 허용되었는지 돌려준다. 이미 거부했다면 다시 묻지 않고 false.
    static func requestAuthorization() async -> Bool {
        switch await authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    @MainActor
    static func openSystemSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    static let categoryID = "newArticle"
    private static let notifiedKey = "notifiedArticleKeys"

    /// 새 글 알림을 보낸다. 앱이 화면에 떠 있으면 목록에서 바로 보이므로 보내지 않는다.
    @MainActor
    static func deliver(_ items: [NewArticle], context: ModelContext) async {
        guard isEnabled, !items.isEmpty, UIApplication.shared.applicationState != .active else { return }
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else { return }
        let feeds = (try? context.fetch(FetchDescriptor<Feed>(predicate: #Predicate { $0.notifies }))) ?? []
        guard !feeds.isEmpty else { return }
        let defaults = UserDefaults.standard
        let notified = defaults.stringArray(forKey: notifiedKey) ?? []
        let groups = NotificationPlanner.plan(new: items, notifyFeedIDs: Set(feeds.map(\.id)),
                                              alreadyNotified: Set(notified))
        guard !groups.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        for group in groups {
            let content = UNMutableNotificationContent()
            content.title = group.feedTitle
            content.body = group.total == 1
                ? group.items[0].title
                : "새 글 \(group.total)개\n" + group.items.map { "• " + $0.title }.joined(separator: "\n")
            content.sound = .default
            content.threadIdentifier = group.feedID.uuidString
            content.categoryIdentifier = categoryID
            content.userInfo = ["articleKey": group.items[0].key]
            if let badge = badgeCount(context) { content.badge = NSNumber(value: badge) }
            try? await center.add(UNNotificationRequest(
                identifier: "new-\(group.feedID.uuidString)-\(Int(Date().timeIntervalSince1970))",
                content: content, trigger: nil))
        }
        defaults.set(NotificationPlanner.trimmed(notified + groups.flatMap(\.keys)), forKey: notifiedKey)
    }

    /// 배지 옵션이 켜져 있으면 읽지 않은 글 수, 아니면 nil
    @MainActor
    static func badgeCount(_ context: ModelContext) -> Int? {
        guard UserDefaults.standard.bool(forKey: AppSettingsKeys.notifyBadge) else { return nil }
        return (try? context.fetchCount(FetchDescriptor<Article>(predicate: #Predicate { $0.isRead == false }))) ?? 0
    }

    /// 앱 아이콘 배지를 지금 상태로 맞춘다 (옵션이 꺼졌으면 지운다)
    @MainActor
    static func updateBadge(_ context: ModelContext) async {
        let count = isEnabled ? (badgeCount(context) ?? 0) : 0
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }

    static let actionRead = "markRead"
    static let actionSave = "saveForLater"

    /// 알림에 붙는 버튼 (앱 시작 때 한 번 등록)
    static func registerCategories() {
        let read = UNNotificationAction(identifier: actionRead, title: "읽음", options: [])
        let save = UNNotificationAction(identifier: actionSave, title: "나중에 읽기", options: [])
        let category = UNNotificationCategory(identifier: categoryID, actions: [read, save],
                                              intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

/// 알림을 눌렀을 때와 알림 버튼을 눌렀을 때의 처리
@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let app: AppModel
    init(app: AppModel) { self.app = app }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let key = response.notification.request.content.userInfo["articleKey"] as? String
        let action = response.actionIdentifier
        await MainActor.run { handle(action: action, key: key) }
    }

    func handle(action: String, key: String?) {
        guard let key else { return }
        let context = app.container.mainContext
        let article = try? context.fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })).first
        switch action {
        case NotificationService.actionRead:
            article?.setRead(true)
            try? context.save()
            Task { await NotificationService.updateBadge(context) }
        case NotificationService.actionSave:
            article?.setSaved(true)
            try? context.save()
        case UNNotificationDefaultActionIdentifier:
            app.pendingArticleKey = key
        default:
            break
        }
    }
}
