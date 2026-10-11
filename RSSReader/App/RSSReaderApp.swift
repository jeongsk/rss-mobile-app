import SwiftUI
import UserNotifications
import WidgetKit
import SwiftData

@main
struct RSSReaderApp: App {
    let container: ModelContainer
    /// UNUserNotificationCenter 는 delegate 를 약하게 잡으므로 붙들어 둔다
    private static var notificationDelegate: NotificationDelegate?
    @State private var app: AppModel

    init() {
        UserDefaults.standard.register(defaults: [
            AppSettingsKeys.cacheImages: true,
            AppSettingsKeys.backgroundRefresh: true,
            AppSettingsKeys.retentionDays: 30,
            AppSettingsKeys.autoRemoveSaved: true,
        ])
        let container = Persistence.makeContainer()
        self.container = container
        let model = AppModel(container: container)
        _app = State(initialValue: model)
        Self.notificationDelegate = NotificationDelegate(app: model)
        UNUserNotificationCenter.current().delegate = Self.notificationDelegate
        NotificationService.registerCategories()
        BackgroundTasks.registerProcessingTask(container: container)
        _ = FontStore.shared
        SpeechPlayer.shared.configure(container: container)
        #if DEBUG
        DemoData.applyLaunchOptions()
        DemoData.insertFixtureArticle(context: container.mainContext)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task {
                    app.dedupe(context: container.mainContext)
                    AppGroup.writeHeartbeat()
                    WidgetCenter.shared.reloadAllTimelines()
                    #if DEBUG
                    DemoData.applySyncFolder()
                    await DemoData.seedIfRequested(app: app, context: container.mainContext)
                    #endif
                    await app.purge()
                    await app.backfillSearchText()
                }
        }
        .modelContainer(container)
        .backgroundTask(.appRefresh(BackgroundTasks.refreshID)) {
            await BackgroundTasks.runRefresh(container: container)
        }
    }
}
