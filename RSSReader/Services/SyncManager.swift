import Foundation
import UIKit

/// 동기화 폴더(보안 범위 북마크) 관리와 동기화 실행
@MainActor
@Observable
final class SyncManager {
    static let shared = SyncManager()
    nonisolated static let bookmarkKey = "sync.bookmark"
    nonisolated static let deviceNameKey = "sync.deviceName"

    private(set) var folderName: String?
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var isSyncing = false

    var isConfigured: Bool { folderName != nil }

    private init() {
        folderName = Self.resolveFolder()?.lastPathComponent
        lastSync = UserDefaults.standard.object(forKey: "sync.lastSync") as? Date
        UserDefaults.standard.set(UIDevice.current.name, forKey: Self.deviceNameKey)
    }

    /// 저장된 북마크로 폴더 URL 을 얻는다 (백그라운드 작업에서도 사용)
    nonisolated static func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        if stale {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            }
        }
        return url
    }

    /// 백그라운드 작업용: 폴더 접근을 열고 동기화한다
    static func syncInBackground(_ refresher: FeedRefresher) async {
        guard let root = resolveFolder() else { return }
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        let name = UserDefaults.standard.string(forKey: deviceNameKey) ?? "iPhone"
        _ = try? await refresher.sync(root: root, env: .current(deviceName: name))
        UserDefaults.standard.set(Date(), forKey: "sync.lastSync")
    }

    func setFolder(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        folderName = url.lastPathComponent
        lastError = nil
    }

    func disconnect() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        folderName = nil
        lastError = nil
    }

    func sync(using refresher: FeedRefresher) async {
        guard !isSyncing, let root = Self.resolveFolder() else { return }
        isSyncing = true
        defer { isSyncing = false }
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        do {
            let report = try await refresher.sync(root: root, env: .current(deviceName: UIDevice.current.name))
            ReaderSettings.shared.load()
            if report.fontsChanged { FontStore.shared.reload() }
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: "sync.lastSync")
            lastError = nil
        } catch {
            lastError = "동기화 실패: \(error.localizedDescription)"
        }
    }
}
