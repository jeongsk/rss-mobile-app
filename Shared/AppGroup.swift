import Foundation

/// 앱과 위젯이 데이터를 나누는 App Group.
/// 식별자는 project.yml 의 APP_GROUP_ID 에서 Info.plist 로 들어온다 (번들 ID 를 바꿔도 코드를 고칠 필요가 없다).
enum AppGroup {
    static var identifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String
    }

    /// 서명에 App Group 권한이 없으면 nil (무료 계정에서 권한이 안 붙은 경우 등)
    static var containerURL: URL? {
        identifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    static var defaults: UserDefaults? {
        identifier.flatMap { UserDefaults(suiteName: $0) }
    }

    /// 컨테이너 안에 실제로 쓰고 읽을 수 있는지 확인한다
    static var isUsable: Bool {
        guard let url = containerURL?.appending(path: ".probe") else { return false }
        do {
            try Data("ok".utf8).write(to: url)
            return (try? Data(contentsOf: url)) == Data("ok".utf8)
        } catch {
            return false
        }
    }

    // MARK: - W0 연결 확인용 (앱이 쓰고 위젯이 읽는다)

    private static let heartbeatKey = "w0.heartbeat"

    /// 앱이 실행될 때 현재 시각을 공유 저장소에 쓴다
    static func writeHeartbeat(now: Date = Date()) {
        defaults?.set(now, forKey: heartbeatKey)
    }

    static var heartbeat: Date? {
        defaults?.object(forKey: heartbeatKey) as? Date
    }
}
