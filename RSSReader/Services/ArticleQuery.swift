import Foundation
import SwiftData

/// 글 목록의 조건 하나로 합친 쿼리. 화면(스코프)과 검색어를 한 Predicate 로 만든다.
struct ArticleQuery: Equatable {
    /// nil 이면 피드 제한 없음
    var feedIDs: [UUID]?
    var starredOnly = false
    var savedOnly = false
    var unreadOnly = false
    /// 읽음 처리했지만 이 화면을 떠날 때까지는 목록에 남겨 둘 글
    var keepVisible: Set<String> = []
    var search = ""

    var predicate: Predicate<Article> {
        let useFeeds = feedIDs != nil
        let ids = feedIDs ?? []
        let starred = starredOnly
        let saved = savedOnly
        let unread = unreadOnly
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        // 검색 중에는 남겨 둘 글 없이 결과만 보여준다
        let keep = q.isEmpty ? Array(keepVisible) : []
        // 컴파일러가 한 번에 못 풀 만큼 커지지 않도록 조건을 쪼갠 변형 중 하나를 고른다
        if useFeeds {
            return #Predicate<Article> { a in
                keep.contains(a.key)
                    || (ids.contains(a.feedID) && (!unread || a.isRead == false)
                        && (q.isEmpty || a.searchText.localizedStandardContains(q)))
            }
        }
        return #Predicate<Article> { a in
            keep.contains(a.key)
                || ((!starred || a.isStarred) && (!saved || a.savedAt != nil) && (!unread || a.isRead == false)
                    && (q.isEmpty || a.searchText.localizedStandardContains(q)))
        }
    }
}
