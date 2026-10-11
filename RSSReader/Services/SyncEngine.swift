import Foundation
import SwiftData

// iCloud Drive 폴더 동기화
//
// 사용자가 고른 폴더(예: iCloud Drive/내 RSS 동기화) 안에
//   devices/<기기 ID>.json   각 기기가 자기 파일만 쓴다 → iCloud 충돌 사본이 생기지 않음
//   fonts/<파일>             사용자 폰트
// 를 두고, 다른 기기 파일을 읽어 병합한 뒤 내 파일을 다시 쓴다.
// 병합 규칙: 같은 대상이면 updatedAt 이 더 최신인 쪽이 이긴다. 원격 값을 적용할 때는
// 원격의 updatedAt 을 그대로 복사해 기기끼리 서로 덮어쓰는 핑퐁을 막는다.

struct SyncSnapshot: Codable, Sendable {
    struct FolderRecord: Codable, Sendable {
        var id: UUID
        var name: String
        var sortOrder: Int
        var updatedAt: Date
    }
    struct FeedRecord: Codable, Sendable {
        var url: String
        var title: String
        var siteURL: String?
        var folderID: UUID?
        var folderName: String?
        var fullTextMode: Int
        /// 새 글 알림 (옛 버전 파일에는 없으므로 옵셔널: nil 이면 건드리지 않는다)
        var notifies: Bool?
        var addedAt: Date
        var updatedAt: Date
    }
    struct ArticleState: Codable, Sendable {
        var key: String
        var isRead: Bool
        var isStarred: Bool
        /// 나중에 읽기 (옛 버전이 만든 파일에는 없으므로 옵셔널: nil 이면 건드리지 않는다)
        var isSaved: Bool?
        var savedAt: Date?
        var updatedAt: Date
        /// 별표·하이라이트·나중에 읽기한 글은 상대 기기에 없을 수 있으므로 글 정보를 함께 보낸다
        var meta: ArticleMeta?
    }
    struct ArticleMeta: Codable, Sendable {
        var title: String
        var link: String
        var feedTitle: String
        var author: String?
        var publishedAt: Date
        var snippet: String
        var imageURL: String?
    }
    struct HighlightRecord: Codable, Sendable {
        var id: UUID
        var articleKey: String
        var articleTitle: String
        var articleLink: String
        var feedTitle: String
        var quote: String
        var prefix: String
        var suffix: String
        var color: String
        var note: String
        var createdAt: Date
        var updatedAt: Date
    }
    struct TombstoneRecord: Codable, Sendable {
        var recordID: String
        var deletedAt: Date
    }

    var version = 1
    var deviceID: String
    var deviceName: String
    var exportedAt: Date
    var folders: [FolderRecord] = []
    var feeds: [FeedRecord] = []
    var articleStates: [ArticleState] = []
    var highlights: [HighlightRecord] = []
    var tombstones: [TombstoneRecord] = []
    var settings: [String: SettingValue] = [:]
    var settingsUpdatedAt: Date = .distantPast
}

/// UserDefaults 값(문자열/숫자/불리언)을 JSON 으로 옮기기 위한 타입
enum SettingValue: Codable, Sendable, Equatable {
    case string(String), double(Double), bool(Bool)

    init?(_ any: Any) {
        // NSNumber 는 Bool/Double 을 구분해야 한다
        if let n = any as? NSNumber {
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .double(n.doubleValue)
        } else if let s = any as? String {
            self = .string(s)
        } else {
            return nil
        }
    }

    var value: Any {
        switch self {
        case .string(let s): s
        case .double(let d): d
        case .bool(let b): b
        }
    }
}

/// 동기화하는 설정 키
enum SyncedSettings {
    static let exactKeys = [
        "listLayouts", "unreadOnly", "translationDisplay", "autoTranslate", "highlightColor",
        "tts.rate", "tts.readTranslation", AppSettingsKeys.retentionDays, AppSettingsKeys.cacheImages, AppSettingsKeys.autoRemoveSaved,
    ] + ReaderSettings.keys.map { ReaderSettings.prefix + $0 }
    static let prefixes = ["tts.voice."]
    static let updatedAtKey = "sync.settingsUpdatedAt"
    static let hashKey = "sync.settingsHash"
    static let fontTombstonesKey = "sync.fontTombstones"

    static func collect(_ defaults: UserDefaults) -> [String: SettingValue] {
        var out: [String: SettingValue] = [:]
        for (key, value) in defaults.dictionaryRepresentation()
        where exactKeys.contains(key) || prefixes.contains(where: key.hasPrefix) {
            if let v = SettingValue(value) { out[key] = v }
        }
        return out
    }

    static func hash(_ settings: [String: SettingValue]) -> String {
        let data = (try? JSONEncoder.sorted.encode(settings)) ?? Data()
        return data.base64EncodedString()
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .secondsSince1970  // 1초 미만까지 보존 (삭제/수정 순서 판단에 필요)
        return e
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}

extension Date {
    /// JSON 왕복 시 생기는 부동소수점 오차(1ms 미만)는 같은 시각으로 본다
    func isNewer(than other: Date) -> Bool { timeIntervalSince(other) > 0.001 }
}

struct SyncReport: Sendable {
    var devicesRead = 0
    var changes = 0
    var fontsChanged = false
}

/// 동기화 환경 (테스트에서 기기별로 바꿔 끼운다)
struct SyncEnvironment: @unchecked Sendable {
    var deviceID: String
    var deviceName: String
    var defaults: UserDefaults
    var fontsDirectory: URL

    static func current(deviceName: String) -> SyncEnvironment {
        let defaults = UserDefaults.standard
        let id: String
        if let existing = defaults.string(forKey: "sync.deviceID") {
            id = existing
        } else {
            id = UUID().uuidString
            defaults.set(id, forKey: "sync.deviceID")
        }
        return SyncEnvironment(deviceID: id, deviceName: deviceName, defaults: defaults,
                               fontsDirectory: FontStore.directory)
    }
}

// MARK: - 파일 입출력 (NSFileCoordinator, 메인 스레드 밖에서 호출)

enum SyncFiles {
    static func devicesDirectory(_ root: URL) -> URL { root.appending(path: "devices", directoryHint: .isDirectory) }
    static func fontsDirectory(_ root: URL) -> URL { root.appending(path: "fonts", directoryHint: .isDirectory) }

    static func ensureDirectories(_ root: URL) throws {
        for dir in [devicesDirectory(root), fontsDirectory(root)] {
            try coordinateWrite(dir) { url in
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }

    /// 폴더 목록. 아직 내려받지 않은 iCloud 파일(.이름.icloud)은 다운로드를 요청하고 이번에는 건너뛴다.
    static func list(_ dir: URL) throws -> [URL] {
        var result: [URL] = []
        var coordError: NSError?
        var thrown: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: [], error: &coordError) { url in
            do {
                let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                for item in items {
                    let name = item.lastPathComponent
                    if name.hasPrefix("."), name.hasSuffix(".icloud") {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: item)
                        continue
                    }
                    if name.hasPrefix(".") { continue }
                    result.append(item)
                }
            } catch {
                thrown = error
            }
        }
        if let error = coordError ?? thrown { throw error }
        return result
    }

    static func read(_ file: URL) throws -> Data {
        var data: Data?
        var coordError: NSError?
        var thrown: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordError) { url in
            do { data = try Data(contentsOf: url) } catch { thrown = error }
        }
        if let error = coordError ?? thrown { throw error }
        return data ?? Data()
    }

    static func write(_ data: Data, to file: URL) throws {
        try coordinateWrite(file) { url in try data.write(to: url, options: .atomic) }
    }

    static func copy(_ source: URL, to dest: URL) throws {
        try coordinateWrite(dest) { url in
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: source, to: url)
        }
    }

    static func remove(_ file: URL) throws {
        var coordError: NSError?
        var thrown: (any Error)?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forDeleting, error: &coordError) { url in
            do { try FileManager.default.removeItem(at: url) } catch { thrown = error }
        }
        if let error = coordError ?? thrown { throw error }
    }

    private static func coordinateWrite(_ file: URL, _ body: (URL) throws -> Void) throws {
        var coordError: NSError?
        var thrown: (any Error)?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordError) { url in
            do { try body(url) } catch { thrown = error }
        }
        if let error = coordError ?? thrown { throw error }
    }
}

// MARK: - 병합 (메인 컨텍스트에서, 파일 입출력만 메인 스레드 밖에서)

@MainActor
extension FeedRefresher {
    /// 동기화 폴더와 한 번 동기화한다. root 는 보안 범위 접근이 열린 상태여야 한다.
    func sync(root: URL, env: SyncEnvironment) async throws -> SyncReport {
        var report = SyncReport()
        let ctx = modelContainer.mainContext

        // 1) 다른 기기 파일 읽기 (iCloud 에서 내려받는 동안 막힐 수 있어 메인 스레드 밖에서)
        let own = "\(env.deviceID).json"
        let remotes: [SyncSnapshot] = try await Task.detached(priority: .utility) {
            try SyncFiles.ensureDirectories(root)
            var out: [SyncSnapshot] = []
            for file in try SyncFiles.list(SyncFiles.devicesDirectory(root))
            where file.pathExtension == "json" && file.lastPathComponent != own {
                if let snap = try? JSONDecoder.iso.decode(SyncSnapshot.self, from: SyncFiles.read(file)) {
                    out.append(snap)
                }
            }
            return out
        }.value
        report.devicesRead = remotes.count
        for snap in remotes.sorted(by: { $0.exportedAt < $1.exportedAt }) {
            report.changes += merge(snap, env: env, ctx: ctx)
        }
        try ctx.save()

        // 2) 폰트
        report.fontsChanged = try await Task.detached(priority: .utility) {
            try Self.syncFonts(root: root, env: env, remotes: remotes)
        }.value

        // 3) 내 파일 쓰기
        let data = try JSONEncoder.sorted.encode(makeSnapshot(env: env, ctx: ctx))
        try await Task.detached(priority: .utility) {
            try SyncFiles.write(data, to: SyncFiles.devicesDirectory(root).appending(path: own))
        }.value
        return report
    }

    func makeSnapshot(env: SyncEnvironment, ctx: ModelContext) -> SyncSnapshot {
        var snap = SyncSnapshot(deviceID: env.deviceID, deviceName: env.deviceName, exportedAt: Date())
        let folders = (try? ctx.fetch(FetchDescriptor<Folder>())) ?? []
        snap.folders = folders.map { .init(id: $0.id, name: $0.name, sortOrder: $0.sortOrder, updatedAt: $0.updatedAt) }
        let feeds = (try? ctx.fetch(FetchDescriptor<Feed>())) ?? []
        snap.feeds = feeds.map {
            .init(url: $0.feedURL, title: $0.title, siteURL: $0.siteURL, folderID: $0.folder?.id,
                  folderName: $0.folder?.name, fullTextMode: $0.fullTextModeRaw, notifies: $0.notifies, addedAt: $0.addedAt, updatedAt: $0.updatedAt)
        }
        // 읽음/별표: 최근 90일 변경분 + 별표 전체
        let since = Date().addingTimeInterval(-90 * 86400)
        let past = Date.distantPast
        let states = (try? ctx.fetch(FetchDescriptor<Article>(
            predicate: #Predicate { $0.stateUpdatedAt > past && ($0.isStarred || $0.savedAt != nil || $0.stateUpdatedAt > since) }))) ?? []
        let highlights = (try? ctx.fetch(FetchDescriptor<Highlight>())) ?? []
        let highlightedKeys = Array(Set(highlights.map(\.articleKey)))
        let highlighted = (try? ctx.fetch(FetchDescriptor<Article>(predicate: #Predicate { highlightedKeys.contains($0.key) }))) ?? []
        var exported = Set<String>()
        for a in states + highlighted where exported.insert(a.key).inserted {
            let needsMeta = a.isStarred || a.isSaved || highlightedKeys.contains(a.key)
            snap.articleStates.append(.init(
                key: a.key, isRead: a.isRead, isStarred: a.isStarred, isSaved: a.isSaved, savedAt: a.savedAt,
                updatedAt: a.stateUpdatedAt,
                meta: needsMeta ? .init(title: a.title, link: a.link, feedTitle: a.feedTitle, author: a.author,
                                        publishedAt: a.publishedAt, snippet: a.snippet, imageURL: a.imageURL) : nil))
        }
        snap.highlights = highlights.map {
            .init(id: $0.id, articleKey: $0.articleKey, articleTitle: $0.articleTitle, articleLink: $0.articleLink,
                  feedTitle: $0.feedTitle, quote: $0.quote, prefix: $0.prefix, suffix: $0.suffix,
                  color: $0.colorRaw, note: $0.note, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
        var tombstones = ((try? ctx.fetch(FetchDescriptor<Tombstone>())) ?? [])
            .map { SyncSnapshot.TombstoneRecord(recordID: $0.recordID, deletedAt: $0.deletedAt) }
        let fontTombstones = env.defaults.dictionary(forKey: SyncedSettings.fontTombstonesKey) as? [String: Date] ?? [:]
        tombstones += fontTombstones.map { .init(recordID: "font:\($0.key)", deletedAt: $0.value) }
        snap.tombstones = tombstones

        // 설정: 값이 바뀌었으면 시각을 갱신
        let settings = SyncedSettings.collect(env.defaults)
        let hash = SyncedSettings.hash(settings)
        if env.defaults.string(forKey: SyncedSettings.hashKey) != hash {
            env.defaults.set(hash, forKey: SyncedSettings.hashKey)
            env.defaults.set(Date(), forKey: SyncedSettings.updatedAtKey)
        }
        snap.settings = settings
        snap.settingsUpdatedAt = env.defaults.object(forKey: SyncedSettings.updatedAtKey) as? Date ?? .distantPast
        return snap
    }

    /// 원격 스냅샷 하나를 로컬에 병합한다. 반환값: 바뀐 항목 수
    @discardableResult
    func merge(_ remote: SyncSnapshot, env: SyncEnvironment, ctx: ModelContext) -> Int {
        var changes = 0

        // 삭제 기록 (먼저 적용해 오래된 파일이 지운 것을 되살리지 않게 한다)
        var tombstones = Dictionary(((try? ctx.fetch(FetchDescriptor<Tombstone>())) ?? []).map { ($0.recordID, $0) },
                                    uniquingKeysWith: { a, _ in a })
        for t in remote.tombstones {
            if let existing = tombstones[t.recordID] {
                if t.deletedAt.isNewer(than: existing.deletedAt) { existing.deletedAt = t.deletedAt }
            } else if !t.recordID.hasPrefix("font:") {
                let new = Tombstone(recordID: t.recordID)
                new.deletedAt = t.deletedAt
                ctx.insert(new)
                tombstones[t.recordID] = new
            }
        }
        func deletedAt(_ id: String) -> Date? {
            if let t = tombstones[id] { return t.deletedAt }
            return remote.tombstones.first { $0.recordID == id }?.deletedAt
        }

        // 폴더: 같은 id → 최신 값, 같은 이름·다른 id → 더 작은 UUID 로 수렴
        var folders = (try? ctx.fetch(FetchDescriptor<Folder>())) ?? []
        for f in folders {
            if let d = deletedAt("folder:\(f.name)"), !f.updatedAt.isNewer(than: d) {
                for feed in f.feeds ?? [] { feed.folder = nil }
                ctx.delete(f)
                changes += 1
            }
        }
        folders = folders.filter { !$0.isDeleted }
        for r in remote.folders {
            if let local = folders.first(where: { $0.id == r.id }) {
                if r.updatedAt.isNewer(than: local.updatedAt) {
                    local.name = r.name; local.sortOrder = r.sortOrder; local.updatedAt = r.updatedAt
                    changes += 1
                }
            } else if let local = folders.first(where: { $0.name == r.name }) {
                if r.id.uuidString < local.id.uuidString { local.id = r.id; changes += 1 }
                if r.updatedAt.isNewer(than: local.updatedAt) { local.sortOrder = r.sortOrder; local.updatedAt = r.updatedAt }
            } else if deletedAt("folder:\(r.name)").map({ r.updatedAt.isNewer(than: $0) }) ?? true {
                let folder = Folder(name: r.name, sortOrder: r.sortOrder)
                folder.id = r.id
                folder.updatedAt = r.updatedAt
                ctx.insert(folder)
                folders.append(folder)
                changes += 1
            }
        }
        func folder(for r: SyncSnapshot.FeedRecord) -> Folder? {
            if let id = r.folderID, let f = folders.first(where: { $0.id == id }) { return f }
            if let name = r.folderName { return folders.first { $0.name == name } }
            return nil
        }

        // 피드: 정규화한 주소가 식별자
        var feeds = (try? ctx.fetch(FetchDescriptor<Feed>())) ?? []
        for f in feeds {
            if let d = deletedAt("feed:\(URLNormalizer.normalize(f.feedURL))"), !f.updatedAt.isNewer(than: d) {
                ctx.delete(f)
                changes += 1
            }
        }
        feeds = feeds.filter { !$0.isDeleted }
        var byURL = Dictionary(feeds.map { (URLNormalizer.normalize($0.feedURL), $0) }, uniquingKeysWith: { a, _ in a })
        for r in remote.feeds {
            let key = URLNormalizer.normalize(r.url)
            if let local = byURL[key] {
                if r.updatedAt.isNewer(than: local.updatedAt) {
                    local.title = r.title
                    local.siteURL = r.siteURL ?? local.siteURL
                    local.fullTextModeRaw = r.fullTextMode
                    if let notifies = r.notifies { local.notifies = notifies }
                    local.folder = folder(for: r)
                    local.updatedAt = r.updatedAt
                    changes += 1
                }
            } else if deletedAt("feed:\(key)").map({ r.updatedAt.isNewer(than: $0) }) ?? true {
                let feed = Feed(title: r.title, feedURL: r.url, siteURL: r.siteURL, folder: folder(for: r))
                feed.fullTextModeRaw = r.fullTextMode
                feed.notifies = r.notifies ?? false
                feed.addedAt = r.addedAt
                feed.updatedAt = r.updatedAt
                ctx.insert(feed)
                byURL[key] = feed
                changes += 1
            }
        }

        // 하이라이트
        let highlights = (try? ctx.fetch(FetchDescriptor<Highlight>())) ?? []
        for h in highlights {
            if let d = deletedAt("highlight:\(h.id.uuidString)"), !h.updatedAt.isNewer(than: d) {
                ctx.delete(h)
                changes += 1
            }
        }
        let byID = Dictionary(highlights.filter { !$0.isDeleted }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for r in remote.highlights {
            if let local = byID[r.id] {
                if r.updatedAt.isNewer(than: local.updatedAt) {
                    local.colorRaw = r.color; local.note = r.note; local.updatedAt = r.updatedAt
                    changes += 1
                }
            } else if deletedAt("highlight:\(r.id.uuidString)").map({ r.updatedAt.isNewer(than: $0) }) ?? true {
                let h = Highlight(articleKey: r.articleKey, articleTitle: r.articleTitle, articleLink: r.articleLink,
                                  feedTitle: r.feedTitle, quote: r.quote, prefix: r.prefix, suffix: r.suffix)
                h.id = r.id
                h.colorRaw = r.color
                h.note = r.note
                h.createdAt = r.createdAt
                h.updatedAt = r.updatedAt
                ctx.insert(h)
                changes += 1
            }
        }

        // 읽음/별표. 별표·하이라이트한 글이 이 기기에 없으면 글 정보로 새로 만들고 본문은 나중에 원문에서 받는다.
        // 그 밖의 글은 이 기기가 같은 글을 받은 뒤 다음 동기화 때 적용된다.
        if !remote.articleStates.isEmpty {
            let keys = remote.articleStates.map(\.key)
            let articles = (try? ctx.fetch(FetchDescriptor<Article>(predicate: #Predicate { keys.contains($0.key) }))) ?? []
            var byKey = Dictionary(articles.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let localHighlightKeys = Set(((try? ctx.fetch(FetchDescriptor<Highlight>())) ?? []).map(\.articleKey))
            let feedsByURL = Dictionary(((try? ctx.fetch(FetchDescriptor<Feed>())) ?? [])
                .map { (URLNormalizer.normalize($0.feedURL), $0) }, uniquingKeysWith: { a, _ in a })
            for s in remote.articleStates {
                if let a = byKey[s.key] {
                    guard s.updatedAt.isNewer(than: a.stateUpdatedAt) else { continue }
                    a.isRead = s.isRead
                    a.isStarred = s.isStarred
                    if let saved = s.isSaved { a.savedAt = saved ? (s.savedAt ?? s.updatedAt) : nil }
                    a.stateUpdatedAt = s.updatedAt
                    changes += 1
                } else if let meta = s.meta, s.isStarred || s.isSaved == true || localHighlightKeys.contains(s.key) {
                    let parts = s.key.split(separator: "|", maxSplits: 1).map(String.init)
                    let feed = parts.first.flatMap { feedsByURL[$0] }
                    let a = Article(key: s.key, feedID: feed?.id ?? UUID(), feedTitle: meta.feedTitle,
                                    guid: parts.count > 1 ? parts[1] : s.key, title: meta.title, link: meta.link,
                                    author: meta.author, feedHTML: "", publishedAt: meta.publishedAt,
                                    imageURL: meta.imageURL)
                    a.snippet = meta.snippet
                    a.isRead = s.isRead
                    a.isStarred = s.isStarred
                    if s.isSaved == true { a.savedAt = s.savedAt ?? s.updatedAt }
                    a.stateUpdatedAt = s.updatedAt
                    ctx.insert(a)
                    byKey[s.key] = a
                    changes += 1
                }
            }
        }

        // 설정
        let localSettingsDate = env.defaults.object(forKey: SyncedSettings.updatedAtKey) as? Date ?? .distantPast
        if remote.settingsUpdatedAt.isNewer(than: localSettingsDate), !remote.settings.isEmpty {
            for (key, value) in remote.settings { env.defaults.set(value.value, forKey: key) }
            env.defaults.set(remote.settingsUpdatedAt, forKey: SyncedSettings.updatedAtKey)
            env.defaults.set(SyncedSettings.hash(SyncedSettings.collect(env.defaults)), forKey: SyncedSettings.hashKey)
            changes += 1
        }
        return changes
    }

    /// 폰트 파일을 양방향으로 맞춘다. 반환값: 로컬 폰트가 바뀌었는지
    nonisolated private static func syncFonts(root: URL, env: SyncEnvironment, remotes: [SyncSnapshot]) throws -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: env.fontsDirectory, withIntermediateDirectories: true)
        var localTombs = env.defaults.dictionary(forKey: SyncedSettings.fontTombstonesKey) as? [String: Date] ?? [:]
        for snap in remotes {
            for t in snap.tombstones where t.recordID.hasPrefix("font:") {
                let name = String(t.recordID.dropFirst(5))
                if localTombs[name].map({ t.deletedAt.isNewer(than: $0) }) ?? true { localTombs[name] = t.deletedAt }
            }
        }
        env.defaults.set(localTombs, forKey: SyncedSettings.fontTombstonesKey)

        var changed = false
        let remoteDir = SyncFiles.fontsDirectory(root)
        let remoteFiles = Dictionary(try SyncFiles.list(remoteDir).map { ($0.lastPathComponent, $0) },
                                     uniquingKeysWith: { a, _ in a })
        let localFiles = Dictionary(((try? fm.contentsOfDirectory(at: env.fontsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })

        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }

        // 삭제 기록 적용
        for (name, deleted) in localTombs {
            if let local = localFiles[name], modified(local) <= deleted {
                try? fm.removeItem(at: local)
                changed = true
            }
            if let remote = remoteFiles[name], modified(remote) <= deleted {
                try? SyncFiles.remove(remote)
            }
        }
        // 원격 → 로컬
        for (name, remote) in remoteFiles where localFiles[name] == nil {
            if let deleted = localTombs[name], modified(remote) <= deleted { continue }
            try SyncFiles.copy(remote, to: env.fontsDirectory.appending(path: name))
            changed = true
        }
        // 로컬 → 원격
        for (name, local) in localFiles where remoteFiles[name] == nil {
            if let deleted = localTombs[name], modified(local) <= deleted { continue }
            try SyncFiles.copy(local, to: remoteDir.appending(path: name))
        }
        return changed
    }
}
