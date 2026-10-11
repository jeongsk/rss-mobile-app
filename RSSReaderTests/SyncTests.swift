import Testing
import Foundation
import SwiftData
@testable import RSSReader

/// 두 가상 기기(A, B)가 같은 임시 폴더를 동기화 폴더로 쓰는 시나리오
@MainActor
final class SyncHarness {
    struct Device {
        let container: ModelContainer
        let refresher: FeedRefresher
        let env: SyncEnvironment
        @MainActor var ctx: ModelContext { container.mainContext }
    }

    let root = FileManager.default.temporaryDirectory.appending(path: "sync-\(UUID().uuidString)")
    lazy var a = makeDevice("A")
    lazy var b = makeDevice("B")

    func makeDevice(_ name: String) -> Device {
        let container = Persistence.makeContainer(inMemory: true)
        let defaults = UserDefaults(suiteName: "sync-test-\(name)-\(UUID().uuidString)")!
        let fonts = FileManager.default.temporaryDirectory.appending(path: "fonts-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        return Device(container: container, refresher: FeedRefresher(modelContainer: container),
                      env: SyncEnvironment(deviceID: name, deviceName: name, defaults: defaults, fontsDirectory: fonts))
    }

    @discardableResult
    func sync(_ d: Device) async throws -> SyncReport {
        try d.ctx.save()
        return try await d.refresher.sync(root: root, env: d.env)
    }

    func importOPML(_ d: Device) {
        let folder = Folder(name: "Tech")
        d.ctx.insert(folder)
        d.ctx.insert(Feed(title: "Swift", feedURL: "https://swift.org/atom.xml", folder: folder))
        d.ctx.insert(Feed(title: "Loose", feedURL: "http://www.loose.example/feed/"))
        try? d.ctx.save()
    }

    /// 동기화 결과는 새 컨텍스트로 읽는다 (메인 컨텍스트 객체는 백그라운드 변경을 바로 반영하지 않을 수 있음)
    func fresh(_ d: Device) -> ModelContext { ModelContext(d.container) }

    func feeds(_ d: Device) -> [Feed] { (try? d.ctx.fetch(FetchDescriptor<Feed>(sortBy: [SortDescriptor(\.feedURL)]))) ?? [] }
    func folders(_ d: Device) -> [Folder] { (try? fresh(d).fetch(FetchDescriptor<Folder>())) ?? [] }

    func addArticle(_ d: Device, feedURL: String = "https://swift.org/atom.xml", guid: String = "post-1") -> Article {
        let feed = feeds(d).first { URLNormalizer.normalize($0.feedURL) == URLNormalizer.normalize(feedURL) }!
        let a = Article(key: Article.makeKey(feedURL: feedURL, guid: guid), feedID: feed.id, feedTitle: feed.title,
                        guid: guid, title: "Post", link: "https://swift.org/p", author: nil, feedHTML: "<p>x</p>",
                        publishedAt: Date())
        d.ctx.insert(a)
        try? d.ctx.save()
        return a
    }
}

@MainActor
struct SyncTests {
    @Test func sameOPMLOnBothDevicesConverges() async throws {
        let h = SyncHarness()
        h.importOPML(h.a)
        h.importOPML(h.b)
        try await h.sync(h.a)
        try await h.sync(h.b)
        try await h.sync(h.a)
        #expect(h.feeds(h.a).count == 2 && h.feeds(h.b).count == 2)
        #expect(h.folders(h.a).count == 1 && h.folders(h.b).count == 1)
        #expect(h.folders(h.a).first?.id == h.folders(h.b).first?.id)
        #expect(h.feeds(h.b).first { $0.title == "Swift" }?.folder?.name == "Tech")
    }

    @Test func readStateFollowsArticleAcrossDevices() async throws {
        let h = SyncHarness()
        h.importOPML(h.a)
        try await h.sync(h.a)
        try await h.sync(h.b)   // B 는 구독을 받는다
        let onA = h.addArticle(h.a)
        onA.setRead(true)
        onA.setStarred(true)
        try await h.sync(h.a)
        let key = h.addArticle(h.b).key  // B 가 같은 글을 나중에 받아도
        try await h.sync(h.b)            // 다음 동기화에서 상태가 적용된다
        let onB = try #require(try h.fresh(h.b).fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })).first)
        #expect(onB.isRead && onB.isStarred)
        #expect(abs(onB.stateUpdatedAt.timeIntervalSince(onA.stateUpdatedAt)) < 0.001)
    }

    @Test func deletedFeedDoesNotComeBack() async throws {
        let h = SyncHarness()
        h.importOPML(h.a)
        try await h.sync(h.a)
        try await h.sync(h.b)
        let feed = h.feeds(h.a).first { $0.title == "Loose" }!
        h.a.ctx.insert(Tombstone.after(feed.updatedAt, recordID: "feed:\(URLNormalizer.normalize(feed.feedURL))"))
        h.a.ctx.delete(feed)
        try await h.sync(h.a)
        // B 의 오래된 파일에는 아직 Loose 가 있지만 A 에 되살아나면 안 된다
        try await h.sync(h.a)
        try await h.sync(h.b)
        try await h.sync(h.a)
        #expect(!h.feeds(h.a).contains { $0.title == "Loose" })
        #expect(!h.feeds(h.b).contains { $0.title == "Loose" })
        #expect(h.feeds(h.b).count == 1)
    }

    @Test func folderRenamePropagatesAfterConvergence() async throws {
        let h = SyncHarness()
        h.importOPML(h.a)
        h.importOPML(h.b)
        try await h.sync(h.a)
        try await h.sync(h.b)
        try await h.sync(h.a)
        let folder = try #require(try h.a.ctx.fetch(FetchDescriptor<Folder>()).first)
        folder.name = "기술"
        folder.updatedAt = Date().addingTimeInterval(5)
        try await h.sync(h.a)
        try await h.sync(h.b)
        #expect(h.folders(h.b).map(\.name) == ["기술"])
    }

    @Test func newerHighlightEditWins() async throws {
        let h = SyncHarness()
        let hl = Highlight(articleKey: "k", articleTitle: "t", articleLink: "l", feedTitle: "f", quote: "q", prefix: "", suffix: "")
        h.a.ctx.insert(hl)
        try await h.sync(h.a)
        try await h.sync(h.b)
        let onB = try #require(try h.b.ctx.fetch(FetchDescriptor<Highlight>()).first)
        #expect(onB.id == hl.id)
        onB.note = "B 메모"; onB.updatedAt = Date().addingTimeInterval(1)
        hl.note = "A 메모"; hl.updatedAt = Date().addingTimeInterval(2)
        try await h.sync(h.b)
        try await h.sync(h.a)
        try await h.sync(h.b)
        let noteA = try h.fresh(h.a).fetch(FetchDescriptor<Highlight>()).first?.note
        let noteB = try h.fresh(h.b).fetch(FetchDescriptor<Highlight>()).first?.note
        #expect(noteA == "A 메모" && noteB == "A 메모")

        // 삭제도 전파된다
        h.a.ctx.insert(Tombstone.after(hl.updatedAt, recordID: "highlight:\(hl.id.uuidString)"))
        h.a.ctx.delete(hl)
        try await h.sync(h.a)
        try await h.sync(h.b)
        #expect(try h.fresh(h.b).fetch(FetchDescriptor<Highlight>()).isEmpty)
    }

    @Test func settingsNewerWinsWithoutEcho() async throws {
        let h = SyncHarness()
        h.a.env.defaults.set(22.0, forKey: "reader.fontSize")
        h.a.env.defaults.set("sepia", forKey: "reader.theme")
        h.a.env.defaults.set(true, forKey: "autoTranslate")
        try await h.sync(h.a)
        try await h.sync(h.b)
        #expect(h.b.env.defaults.double(forKey: "reader.fontSize") == 22)
        #expect(h.b.env.defaults.string(forKey: "reader.theme") == "sepia")
        #expect(h.b.env.defaults.bool(forKey: "autoTranslate"))
        // 받은 설정을 다시 내보내도 시각이 바뀌지 않아야 한다 (핑퐁 방지)
        let stampB = h.b.env.defaults.object(forKey: SyncedSettings.updatedAtKey) as? Date
        try await h.sync(h.b)
        #expect(h.b.env.defaults.object(forKey: SyncedSettings.updatedAtKey) as? Date == stampB)
        let report = try await h.sync(h.a)
        #expect(report.changes == 0)
    }

    @Test func fontsCopyBothWaysAndDeletionPropagates() async throws {
        let h = SyncHarness()
        let font = h.a.env.fontsDirectory.appending(path: "MyFont.ttf")
        try Data("font-bytes".utf8).write(to: font)
        try await h.sync(h.a)
        let r = try await h.sync(h.b)
        #expect(r.fontsChanged)
        #expect(FileManager.default.fileExists(atPath: h.b.env.fontsDirectory.appending(path: "MyFont.ttf").path))

        // A 에서 삭제
        try FileManager.default.removeItem(at: font)
        h.a.env.defaults.set(["MyFont.ttf": Date().addingTimeInterval(1)], forKey: SyncedSettings.fontTombstonesKey)
        try await h.sync(h.a)
        try await h.sync(h.b)
        #expect(!FileManager.default.fileExists(atPath: h.b.env.fontsDirectory.appending(path: "MyFont.ttf").path))
        #expect(!FileManager.default.fileExists(atPath: font.path))
    }

    @Test func secondSyncIsNoOp() async throws {
        let h = SyncHarness()
        h.importOPML(h.a)
        h.importOPML(h.b)
        _ = h.addArticle(h.a).setRead(true)
        try await h.sync(h.a)
        try await h.sync(h.b)
        try await h.sync(h.a)
        let second = try await h.sync(h.b)
        let third = try await h.sync(h.a)
        #expect(second.changes == 0)
        #expect(third.changes == 0)
    }
}

@MainActor
struct SyncStubTests {
    @Test func starredOldArticleAppearsOnDeviceThatNeverFetchedIt() async throws {
        let h = SyncHarness()
        h.importOPML(h.a)
        try await h.sync(h.a)
        try await h.sync(h.b)
        let old = h.addArticle(h.a, guid: "old-post")
        old.setStarred(true)
        let hl = Highlight(articleKey: old.key, articleTitle: old.title, articleLink: old.link, feedTitle: old.feedTitle,
                           quote: "x", prefix: "", suffix: "")
        h.a.ctx.insert(hl)
        try await h.sync(h.a)
        try await h.sync(h.b)
        let key = old.key
        let onB = try #require(try h.fresh(h.b).fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })).first)
        #expect(onB.isStarred)
        #expect(onB.title == "Post" && onB.link == "https://swift.org/p")
        #expect(onB.contentStatus == .pending)  // 본문은 원문에서 다시 받는다
        let feedOnB = h.feeds(h.b).first { $0.title == "Swift" }
        #expect(onB.feedID == feedOnB?.id)
        // 두 번째 동기화는 중복을 만들지 않는다
        try await h.sync(h.b)
        #expect(try h.fresh(h.b).fetchCount(FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })) == 1)
    }
}

@MainActor
struct SingleWriterTests {
    /// 본문을 가져오는 동안(네트워크 대기) 사용자가 별표·읽음을 바꿔도 둘 다 남는다.
    /// 쓰기를 메인 컨텍스트 하나로 모았기 때문에 같은 객체를 고치게 된다.
    @Test func userEditDuringCachingIsKept() async throws {
        let container = Persistence.makeContainer(inMemory: true)
        let main = container.mainContext
        let feed = Feed(title: "f", feedURL: "https://example.invalid/feed")
        feed.fullTextMode = .never
        main.insert(feed)
        let a = Article(key: "k", feedID: feed.id, feedTitle: "f", guid: "g", title: "t", link: "https://example.invalid/p",
                        author: nil, feedHTML: "<p>x</p>", publishedAt: Date())
        main.insert(a)
        try main.save()
        UserDefaults.standard.set(false, forKey: AppSettingsKeys.cacheImages)
        defer { UserDefaults.standard.set(true, forKey: AppSettingsKeys.cacheImages) }

        let refresher = FeedRefresher(modelContainer: container)
        async let caching: Void = refresher.cache(key: "k")
        a.setStarred(true)
        a.setRead(true)
        await caching

        let check = try #require(try ModelContext(container).fetch(FetchDescriptor<Article>()).first)
        #expect(check.isStarred && check.isRead)
        #expect(check.contentStatus == .feedOnly)
    }
}

@MainActor
struct SyncSavedTests {
    @Test func savedStateAndUnsaveFollowAcrossDevices() async throws {
        let h = SyncHarness()
        h.importOPML(h.a)
        try await h.sync(h.a)
        try await h.sync(h.b)
        let onA = h.addArticle(h.a, guid: "later-post")
        let key = onA.key
        onA.setSaved(true)
        try await h.sync(h.a)
        try await h.sync(h.b)   // B 에는 이 글이 없어도 글 정보로 만들어진다
        var onB = try #require(try h.fresh(h.b).fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })).first)
        #expect(onB.isSaved)
        #expect(abs((onB.savedAt ?? .distantPast).timeIntervalSince(onA.savedAt ?? .distantFuture)) < 0.001)
        // 해제도 전파된다
        let ctxB = h.fresh(h.b)
        let editB = try #require(try ctxB.fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })).first)
        editB.setSaved(false)
        try ctxB.save()
        try await h.sync(h.b)
        try await h.sync(h.a)
        let afterA = try #require(try h.fresh(h.a).fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })).first)
        #expect(!afterA.isSaved)
        onB = try #require(try h.fresh(h.b).fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })).first)
        #expect(!onB.isSaved)
    }

    @Test func oldFilesWithoutSavedFieldDecodeAndKeepLocalSaved() throws {
        let json = #"{"key":"k","isRead":true,"isStarred":false,"updatedAt":0}"#
        let state = try JSONDecoder().decode(SyncSnapshot.ArticleState.self, from: Data(json.utf8))
        #expect(state.isSaved == nil && state.savedAt == nil)
    }

    @Test func purgeKeepsSavedArticles() async throws {
        let key = AppSettingsKeys.retentionDays
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(30, forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let h = SyncHarness()
        h.importOPML(h.a)
        let kept = h.addArticle(h.a, guid: "kept")
        let gone = h.addArticle(h.a, guid: "gone")
        for a in [kept, gone] { a.publishedAt = Date().addingTimeInterval(-100 * 86400) }
        kept.setSaved(true)
        try h.a.ctx.save()
        await h.a.refresher.purgeOld()
        let keys = Set(try h.fresh(h.a).fetch(FetchDescriptor<Article>()).map(\.key))
        #expect(keys.contains(kept.key) && !keys.contains(gone.key))
    }
}

@MainActor
struct SyncNotifyTests {
    @Test func feedNotifyFlagFollowsAcrossDevicesAndOldFilesAreIgnored() async throws {
        let h = SyncHarness()
        h.importOPML(h.a)
        try await h.sync(h.a)
        try await h.sync(h.b)
        #expect(h.feeds(h.b).allSatisfy { !$0.notifies })
        let feed = h.feeds(h.a).first { $0.title == "Swift" }!
        feed.notifies = true
        feed.updatedAt = Date().addingTimeInterval(1)
        try await h.sync(h.a)
        try await h.sync(h.b)
        let onB = try h.fresh(h.b).fetch(FetchDescriptor<Feed>()).first { $0.title == "Swift" }
        #expect(onB?.notifies == true)
        #expect(try h.fresh(h.b).fetch(FetchDescriptor<Feed>()).first { $0.title == "Loose" }?.notifies == false)

        let json = #"{"url":"u","title":"t","fullTextMode":0,"addedAt":0,"updatedAt":0}"#
        let record = try JSONDecoder().decode(SyncSnapshot.FeedRecord.self, from: Data(json.utf8))
        #expect(record.notifies == nil)
    }
}
