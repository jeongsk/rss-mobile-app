import Foundation

/// 새 글 중 무엇을 어떻게 알릴지 정한다. 순수 함수라 테스트하기 쉽다.
enum NotificationPlanner {
    struct Group: Equatable {
        var feedID: UUID
        var feedTitle: String
        /// 최신순, 알림에 제목을 보여줄 글
        var items: [NewArticle]
        /// 이 피드의 전체 새 글 수
        var total: Int
        /// 이 피드에서 알리는 모든 글의 키 (알린 기록에 남긴다)
        var keys: [String]
    }

    /// 발행한 지 이만큼 지난 글은 알리지 않는다 (오래된 글이 뒤늦게 들어와도 조용히)
    static let maxAge: TimeInterval = 24 * 3600
    /// 한 번에 보내는 피드 알림 수
    static let maxGroups = 5
    /// 한 피드 알림에 제목을 보여줄 글 수
    static let maxTitles = 3

    static func plan(new: [NewArticle], notifyFeedIDs: Set<UUID>, alreadyNotified: Set<String>,
                     now: Date = Date()) -> [Group] {
        let cutoff = now.addingTimeInterval(-maxAge)
        let candidates = new
            .filter { notifyFeedIDs.contains($0.feedID) && !alreadyNotified.contains($0.key) && $0.publishedAt >= cutoff }
            .sorted { $0.publishedAt > $1.publishedAt }
        var order: [UUID] = []
        var byFeed: [UUID: [NewArticle]] = [:]
        for item in candidates {
            if byFeed[item.feedID] == nil { order.append(item.feedID) }
            byFeed[item.feedID, default: []].append(item)
        }
        return order.prefix(maxGroups).map { id in
            let items = byFeed[id]!
            return Group(feedID: id, feedTitle: items[0].feedTitle,
                         items: Array(items.prefix(maxTitles)), total: items.count, keys: items.map(\.key))
        }
    }

    /// 알린 글 키 기록은 최근 것만 남긴다
    static func trimmed(_ keys: [String], limit: Int = 500) -> [String] {
        keys.count > limit ? Array(keys.suffix(limit)) : keys
    }
}
