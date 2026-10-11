import Foundation
import BackgroundTasks
import SwiftData

/// 백그라운드 갱신
/// - appRefresh: 약 30초 안에 피드를 갱신하고 최신 글 일부를 캐시
/// - processing: 충전/유휴 시간에 남은 글의 전체 본문과 이미지를 캐시
enum BackgroundTasks {
    static let refreshID = "com.anpigon.RSSReader.refresh"
    static let cacheID = "com.anpigon.RSSReader.cache"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: AppSettingsKeys.backgroundRefresh) as? Bool ?? true
    }

    static func scheduleAll() {
        guard isEnabled else {
            BGTaskScheduler.shared.cancelAllTaskRequests()
            return
        }
        scheduleRefresh()
        scheduleCache()
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func scheduleCache() {
        let request = BGProcessingTaskRequest(identifier: cacheID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// SwiftUI `.backgroundTask(.appRefresh)` 에서 호출
    @MainActor
    static func runRefresh(container: ModelContainer) async {
        guard isEnabled else { return }
        scheduleRefresh()
        let refresher = FeedRefresher(modelContainer: container)
        _ = await refresher.refreshAll()
        await SyncManager.syncInBackground(refresher)
        await refresher.cachePending(limit: 15, until: Date(timeIntervalSinceNow: 15))
        scheduleCache()
    }

    /// 앱 실행 직후(init) 등록해야 한다.
    static func registerProcessingTask(container: ModelContainer) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: cacheID, using: nil) { task in
            let box = UncheckedBox(task)
            let work = Task { @MainActor in
                let refresher = FeedRefresher(modelContainer: container)
                await refresher.cachePending(limit: 300)
                await refresher.purgeOld()
                box.value.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
    }
}

/// BGTask 는 Sendable 이 아니지만 완료 통보는 어느 스레드에서 해도 안전하다.
final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
